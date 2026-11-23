package cli

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

// Releases publish one binary per platform, named amber-<os>-<arch>, and a
// checksums.txt in sha256sum format. The Lua library is the tagged commit.
const releaseRepo = "rawnly/amber"

func selfUpdateCommand(g *globals) *cobra.Command {
	var checkOnly bool
	var dir string
	cmd := &cobra.Command{
		Use:   "self-update",
		Short: "Update Amber itself to the latest release",
		Long: "Download the latest release of this binary and move the Amber library checkout to the same tag, " +
			"so the two always match, then reload Rex. The library checkout must be clean and either on main or detached.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return selfUpdate(cmd.Context(), g, dir, checkOnly)
		},
	}
	cmd.Flags().BoolVar(&checkOnly, "check", false, "only report whether a newer release exists")
	cmd.Flags().StringVar(&dir, "dir", "", "Amber library checkout (default: the directory containing bin/amber)")
	return cmd
}

type release struct {
	Tag    string `json:"tag_name"`
	Assets []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
	} `json:"assets"`
}

func (r release) asset(name string) string {
	for _, a := range r.Assets {
		if a.Name == name {
			return a.URL
		}
	}
	return ""
}

func selfUpdate(ctx context.Context, g *globals, dir string, checkOnly bool) error {
	rel, err := latestRelease(ctx)
	if err != nil {
		return err
	}
	current := Version
	if strings.TrimPrefix(current, "v") == strings.TrimPrefix(rel.Tag, "v") {
		fmt.Printf("Amber %s is the latest release.\n", current)
		return nil
	}
	fmt.Printf("Amber %s is available (you have %s).\n", rel.Tag, current)
	if checkOnly {
		return nil
	}

	exe, err := os.Executable()
	if err != nil {
		return err
	}
	if exe, err = filepath.EvalSymlinks(exe); err != nil {
		return err
	}
	if dir == "" {
		dir = filepath.Dir(filepath.Dir(exe))
	}
	if _, err := os.Stat(filepath.Join(dir, "amber.lua")); err != nil {
		return fmt.Errorf("no Amber library at %s; pass --dir", dir)
	}
	if err := checkLibrary(ctx, dir); err != nil {
		return err
	}

	name := fmt.Sprintf("amber-%s-%s", runtime.GOOS, runtime.GOARCH)
	binURL, sumURL := rel.asset(name), rel.asset("checksums.txt")
	if binURL == "" || sumURL == "" {
		return fmt.Errorf("release %s has no %s binary or checksums.txt", rel.Tag, name)
	}
	want, err := checksum(ctx, sumURL, name)
	if err != nil {
		return err
	}

	// Library first: if the binary download fails afterwards, the old binary
	// still works with a newer library more often than the reverse.
	fmt.Printf("Moving %s to %s…\n", dir, rel.Tag)
	if out, err := gitIn(ctx, dir, "fetch", "--tags", "origin"); err != nil {
		return fmt.Errorf("cannot fetch the Amber library: %s", out)
	}
	if out, err := gitIn(ctx, dir, "checkout", "--detach", rel.Tag, "--"); err != nil {
		return fmt.Errorf("cannot check out %s: %s", rel.Tag, out)
	}

	fmt.Printf("Downloading %s…\n", name)
	if err := replaceBinary(ctx, exe, binURL, want); err != nil {
		return err
	}
	fmt.Printf("Updated Amber to %s.\n", rel.Tag)

	if g.noReload {
		return nil
	}
	c, err := g.connect(ctx)
	if err != nil {
		fmt.Println("Reload Rex to load the new library: rex config reload")
		return nil
	}
	defer c.Close()
	if c.session.Reload != nil {
		if _, err := c.session.Reload(ctx); err == nil {
			fmt.Println("Reloaded Rex config.")
		} else {
			fmt.Println("Reload Rex to load the new library:", err)
		}
	}
	return nil
}

// checkLibrary refuses to move a checkout that has local work on it, such as
// a development clone.
func checkLibrary(ctx context.Context, dir string) error {
	if out, err := gitIn(ctx, dir, "status", "--porcelain", "--untracked-files=normal"); err != nil {
		return fmt.Errorf("%s is not a Git checkout: %s", dir, out)
	} else if out != "" {
		return fmt.Errorf("%s has local changes; self-update only moves clean release checkouts", dir)
	}
	branch, _ := gitIn(ctx, dir, "symbolic-ref", "--quiet", "--short", "HEAD")
	if branch != "" && branch != "main" {
		return fmt.Errorf("%s is on branch %s; self-update only moves checkouts on main or a release tag", dir, branch)
	}
	return nil
}

func gitIn(ctx context.Context, dir string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func httpGet(ctx context.Context, url string) (*http.Response, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		cancel()
		return nil, err
	}
	req.Header.Set("User-Agent", "amber/"+Version)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		cancel()
		return nil, err
	}
	if res.StatusCode != http.StatusOK {
		res.Body.Close()
		cancel()
		return nil, fmt.Errorf("GET %s: %s", url, res.Status)
	}
	body := res.Body
	res.Body = struct {
		io.Reader
		io.Closer
	}{body, closerFunc(func() error { cancel(); return body.Close() })}
	return res, nil
}

type closerFunc func() error

func (f closerFunc) Close() error { return f() }

func latestRelease(ctx context.Context) (release, error) {
	var rel release
	res, err := httpGet(ctx, "https://api.github.com/repos/"+releaseRepo+"/releases/latest")
	if err != nil {
		return rel, fmt.Errorf("cannot find the latest Amber release: %w", err)
	}
	defer res.Body.Close()
	if err := json.NewDecoder(res.Body).Decode(&rel); err != nil || rel.Tag == "" {
		return rel, errors.New("cannot read the latest Amber release from GitHub")
	}
	return rel, nil
}

func checksum(ctx context.Context, url, name string) (string, error) {
	res, err := httpGet(ctx, url)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	sc := bufio.NewScanner(res.Body)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == name {
			return f[0], nil
		}
	}
	return "", fmt.Errorf("checksums.txt has no entry for %s", name)
}

// replaceBinary downloads to a temporary file next to exe, verifies its
// checksum, and renames it over exe.
func replaceBinary(ctx context.Context, exe, url, want string) error {
	res, err := httpGet(ctx, url)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	tmp, err := os.CreateTemp(filepath.Dir(exe), ".amber-update-*")
	if err != nil {
		return fmt.Errorf("cannot write next to %s: %w", exe, err)
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(tmp, h), res.Body); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != want {
		return fmt.Errorf("checksum mismatch for the downloaded binary (got %s, want %s)", got, want)
	}
	if err := os.Chmod(tmp.Name(), 0o755); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), exe)
}
