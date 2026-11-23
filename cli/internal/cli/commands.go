package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/rawnly/amber/cli/internal/engine"
	"github.com/rawnly/amber/cli/internal/rex"
	"github.com/rawnly/amber/cli/internal/ui"
)

func listCommand(g *globals) *cobra.Command {
	var asJSON bool
	cmd := &cobra.Command{
		Use:     "list",
		Aliases: []string{"ls"},
		Short:   "List plugins and their state",
		Long:    "List declared plugins with their load status, commit, and version. Reads local state only; nothing is fetched.",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runList(cmd.Context(), g, asJSON)
		},
	}
	cmd.Flags().BoolVar(&asJSON, "json", false, "print JSON")
	return cmd
}

func runList(ctx context.Context, g *globals, asJSON bool) error {
	c, err := g.connect(ctx)
	if err != nil {
		return err
	}
	defer c.Close()
	states := map[string]engine.State{}
	for i := range c.info.Plugins {
		p := &c.info.Plugins[i]
		states[p.Name] = c.session.Backend.State(ctx, p)
	}
	if !asJSON {
		ui.PrintList(os.Stdout, c.info, states)
		return nil
	}
	type item struct {
		Name       string `json:"name"`
		Enabled    bool   `json:"enabled"`
		Local      bool   `json:"local"`
		Dir        string `json:"dir"`
		Version    string `json:"version,omitempty"`
		LoadStatus string `json:"load_status,omitempty"`
		LoadError  string `json:"load_error,omitempty"`
		Installed  bool   `json:"installed"`
		Commit     string `json:"commit,omitempty"`
		Branch     string `json:"branch,omitempty"`
		Locked     string `json:"locked,omitempty"`
		Dirty      bool   `json:"dirty"`
		NeedsBuild bool   `json:"needs_build"`
		Error      string `json:"error,omitempty"`
	}
	out := make([]item, 0, len(c.info.Plugins))
	for _, p := range c.info.Plugins {
		st := states[p.Name]
		it := item{
			Name: p.Name, Enabled: p.Enabled, Local: p.LocalPath, Dir: p.Dir, Version: p.Version,
			LoadStatus: p.LoadStatus, LoadError: p.LoadError, Installed: st.Installed, Commit: st.Head,
			Branch: st.Branch, Locked: st.Locked, Dirty: st.Dirty, NeedsBuild: st.NeedsBuild,
		}
		if st.Err != nil {
			it.Error = st.Err.Error()
		}
		out = append(out, it)
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(out)
}

func cleanCommand(g *globals) *cobra.Command {
	var dryRun, yes, withLock bool
	cmd := &cobra.Command{
		Use:   "clean",
		Short: "Remove undeclared checkouts and leftovers",
		Long: "Remove checkouts under the plugin root that no spec declares, clone directories and locks left by " +
			"interrupted runs, and with --lock, lockfile entries of undeclared plugins. Removed directories are " +
			"deleted for good, including local changes in them.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := cmd.Context()
			if !dryRun && !yes && !g.plain && interactive() {
				return g.ui(ui.OpClean, "", withLock)
			}
			c, err := g.connect(ctx)
			if err != nil {
				return err
			}
			defer c.Close()
			items, err := c.session.Backend.CleanPlan(ctx, withLock)
			if err != nil {
				return err
			}
			if len(items) == 0 {
				fmt.Println("Nothing to clean.")
				return nil
			}
			for _, it := range items {
				target := it.Path
				if it.Kind == engine.CleanLockEntry {
					target = it.Name + " (lockfile entry)"
				}
				fmt.Printf("%-14s %s\n", it.Kind, target)
			}
			if dryRun || !yes {
				if !dryRun {
					fmt.Println("\nNothing removed; run again with --yes to remove these.")
				}
				return nil
			}
			if err := c.session.Backend.Clean(ctx, items); err != nil {
				return err
			}
			fmt.Printf("\nRemoved %d item(s).\n", len(items))
			return nil
		},
	}
	f := cmd.Flags()
	f.BoolVarP(&dryRun, "dry-run", "n", false, "only list what would be removed")
	f.BoolVarP(&yes, "yes", "y", false, "remove without asking")
	f.BoolVar(&withLock, "lock", false, "also remove lockfile entries of undeclared plugins")
	return cmd
}

func doctorCommand(g *globals) *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Check Rex, Git, the lockfile, and every plugin",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runDoctor(cmd.Context(), g)
		},
	}
}

func runDoctor(ctx context.Context, g *globals) error {
	out := os.Stdout
	failed := false
	add := func(list *[]ui.CheckResult, level ui.CheckLevel, title, detail string) {
		*list = append(*list, ui.CheckResult{Level: level, Title: title, Detail: detail})
		if level == ui.CheckFail {
			failed = true
		}
	}

	var env []ui.CheckResult
	if path, err := exec.LookPath("git"); err != nil {
		add(&env, ui.CheckFail, "git is not on PATH", "Amber needs Git to install and update plugins")
	} else {
		v, _ := exec.CommandContext(ctx, path, "--version").Output()
		add(&env, ui.CheckOK, strings.TrimSpace(string(v)), "")
	}

	dialCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	client, err := rex.Dial(dialCtx, g.server, Version)
	cancel()
	if err != nil {
		add(&env, ui.CheckFail, "cannot reach the Rex server", err.Error())
		ui.PrintChecks(out, "Environment", env)
		return ui.ErrFailed
	}
	defer client.Close()
	if v, err := client.Version(ctx); err == nil {
		add(&env, ui.CheckOK, fmt.Sprintf("Rex %s (API revision %d)", v.RexVersion, client.Revision()), "")
	}

	c, err := g.connect(ctx)
	if err != nil {
		add(&env, ui.CheckFail, "Amber is not loaded by the Rex config", err.Error())
		ui.PrintChecks(out, "Environment", env)
		return ui.ErrFailed
	}
	defer c.Close()
	info := c.info
	lib := "Amber library " + info.Version + " at " + info.Dir
	switch {
	case Version == "dev" || info.Version == "":
		add(&env, ui.CheckOK, lib, "")
	case strings.TrimPrefix(Version, "v") != strings.TrimPrefix(info.Version, "v"):
		add(&env, ui.CheckWarn, lib, fmt.Sprintf("this CLI is %s; run: amber self-update", Version))
	default:
		add(&env, ui.CheckOK, lib, "")
	}
	ui.PrintChecks(out, "Environment", env)

	var files []ui.CheckResult
	if info.LockError != "" {
		add(&files, ui.CheckFail, "lockfile cannot be read: "+info.Lockfile, info.LockError+"\nAmber never overwrites it; fix or remove it.")
	} else {
		add(&files, ui.CheckOK, "lockfile "+info.Lockfile, "")
	}
	if items, err := c.session.Backend.CleanPlan(ctx, false); err != nil {
		add(&files, ui.CheckWarn, "cannot scan "+info.Root, err.Error())
	} else {
		for _, it := range items {
			switch it.Kind {
			case engine.CleanLockfileGuard, engine.CleanInstallLock:
				add(&files, ui.CheckWarn, "leftover "+string(it.Kind)+": "+it.Path,
					"commands fail while it exists; if no Amber command is running, run: amber clean")
			case engine.CleanTemp:
				add(&files, ui.CheckWarn, "leftover clone directory: "+it.Path, "run: amber clean")
			case engine.CleanOrphan:
				add(&files, ui.CheckWarn, "undeclared checkout: "+it.Path, "remove it with: amber clean")
			}
		}
	}
	ui.PrintChecks(out, "Files", files)

	states := map[string]engine.State{}
	for i := range info.Plugins {
		p := &info.Plugins[i]
		states[p.Name] = c.session.Backend.State(ctx, p)
	}
	if checks := ui.PluginChecks(info, states); len(checks) > 0 {
		ui.PrintChecks(out, "Plugins", checks)
	}
	if failed {
		return ui.ErrFailed
	}
	return nil
}

var errNotRelease = errors.New("not a release install")
