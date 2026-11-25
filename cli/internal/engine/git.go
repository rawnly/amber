package engine

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	networkTimeout = 10 * time.Minute
	localTimeout   = time.Minute
	// waitDelay bounds how long a killed command's children may keep its
	// output pipes open, so cancel and timeouts actually return.
	waitDelay = 5 * time.Second
)

// output receives a command's output: log lines, and Git's progress
// percentages, which it rewrites in place with \r.
type output struct {
	line     func(string)
	progress func(float64)
}

var percent = regexp.MustCompile(`(\d{1,3})%`)

// writer splits a stream on \n and \r: \n ends a log line, \r a progress
// update that the next one replaces.
func (o output) writer() (io.WriteCloser, func()) {
	r, w := io.Pipe()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		br := bufio.NewReader(r)
		var buf bytes.Buffer
		flush := func(final bool) {
			text := strings.TrimSpace(buf.String())
			buf.Reset()
			if text == "" {
				return
			}
			if m := percent.FindStringSubmatch(text); m != nil && o.progress != nil {
				n, _ := strconv.Atoi(m[1])
				o.progress(float64(min(n, 100)) / 100)
			}
			if final && o.line != nil {
				o.line(text)
			}
		}
		for {
			b, err := br.ReadByte()
			if err != nil {
				flush(true)
				return
			}
			switch b {
			case '\n':
				flush(true)
			case '\r':
				flush(false)
			default:
				buf.WriteByte(b)
			}
		}
	}()
	return w, func() { w.Close(); wg.Wait() }
}

// tail keeps the last lines of stderr for error messages.
type tail struct {
	mu    sync.Mutex
	lines []string
}

func (t *tail) add(s string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.lines = append(t.lines, s)
	if len(t.lines) > 8 {
		t.lines = t.lines[len(t.lines)-8:]
	}
}

func (t *tail) String() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return strings.Join(t.lines, "\n")
}

type gitCall struct {
	dir     string
	network bool
	out     output // streams stderr; stdout is returned
}

// git runs one Git command and returns its trimmed stdout. Failures carry
// Git's stderr, or the exit status when it printed nothing.
func git(ctx context.Context, call gitCall, args ...string) (string, error) {
	timeout := localTimeout
	if call.network {
		timeout = networkTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = call.dir
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "LC_ALL=C")
	cmd.WaitDelay = waitDelay
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	errTail := &tail{}
	o := call.out
	line := o.line
	o.line = func(s string) {
		errTail.add(s)
		if line != nil {
			line(s)
		}
	}
	stderr, wait := o.writer()
	cmd.Stderr = stderr
	err := cmd.Run()
	wait()
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return "", fmt.Errorf("git %s timed out after %s", args[0], timeout)
		}
		if errors.Is(ctx.Err(), context.Canceled) {
			return "", context.Canceled
		}
		if msg := strings.TrimSpace(errTail.String()); msg != "" {
			return "", errors.New(msg)
		}
		return "", fmt.Errorf("git %s: %w", args[0], err)
	}
	return strings.TrimSpace(stdout.String()), nil
}

// gitOK runs a Git command whose exit status is the answer, such as
// merge-base --is-ancestor. Status 1 means false; anything else is an error.
func gitOK(ctx context.Context, dir string, args ...string) (bool, error) {
	ctx, cancel := context.WithTimeout(ctx, localTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "LC_ALL=C")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err == nil {
		return true, nil
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 1 {
		return false, nil
	}
	if msg := strings.TrimSpace(stderr.String()); msg != "" {
		return false, errors.New(msg)
	}
	return false, err
}

var commitPattern = regexp.MustCompile(`^[0-9a-f]{40}([0-9a-f]{24})?$`)

func validCommit(s string) bool { return commitPattern.MatchString(s) }

// revParse resolves a ref to a full commit hash.
func revParse(ctx context.Context, dir, ref string) (string, error) {
	hash, err := git(ctx, gitCall{dir: dir}, "rev-parse", "--verify", "--quiet", ref+"^{commit}")
	if err != nil || hash == "" {
		if err == nil {
			err = fmt.Errorf("unknown revision %s", ref)
		}
		return "", err
	}
	if !validCommit(hash) {
		return "", errors.New("invalid Git commit")
	}
	return hash, nil
}

// commitsBetween lists from..to, newest first, at most 50.
func commitsBetween(ctx context.Context, dir, from, to string) []Commit {
	if from == "" || to == "" || from == to {
		return nil
	}
	out, err := git(ctx, gitCall{dir: dir}, "log", "-n", "50", "--format=%H%x1f%s%x1f%an%x1f%ct", from+".."+to)
	if err != nil || out == "" {
		return nil
	}
	var commits []Commit
	for _, line := range strings.Split(out, "\n") {
		f := strings.Split(line, "\x1f")
		if len(f) != 4 {
			continue
		}
		c := Commit{Hash: f[0], Subject: f[1], Author: f[2]}
		if ts, err := strconv.ParseInt(f[3], 10, 64); err == nil {
			c.When = time.Unix(ts, 0)
		}
		commits = append(commits, c)
	}
	return commits
}

func isDirty(ctx context.Context, dir string) (bool, error) {
	out, err := git(ctx, gitCall{dir: dir}, "status", "--porcelain", "--untracked-files=normal")
	return out != "", err
}

// currentBranch is the checked-out branch, or "" when HEAD is detached.
func currentBranch(ctx context.Context, dir string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, localTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "symbolic-ref", "--quiet", "--short", "HEAD")
	cmd.Dir = dir
	out, err := cmd.Output()
	if err == nil {
		return strings.TrimSpace(string(out)), nil
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 1 {
		return "", nil
	}
	return "", fmt.Errorf("cannot determine checkout branch: %w", err)
}

func installed(dir string) bool {
	_, err := os.Stat(dir + "/.git/HEAD")
	return err == nil
}
