// Package cli wires Amber's commands.
package cli

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/rawnly/amber/cli/internal/ui"
)

// Version is set at build time with -ldflags "-X github.com/rawnly/amber/cli/internal/cli.Version=v1.2.3".
var Version = "dev"

// Execute runs the command line and returns the exit code.
func Execute() int {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	g := &globals{}
	root := &cobra.Command{
		Use:   "amber",
		Short: "Plugin manager for Rex",
		Long: "Amber installs, updates, and loads Rex plugins.\n\n" +
			"Run without a command to open the plugin window.",
		Version:       Version,
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if g.plain || !interactive() {
				return runList(cmd.Context(), g, false)
			}
			return g.ui(ui.OpNone, "", false)
		},
	}
	pf := root.PersistentFlags()
	pf.StringVar(&g.server, "server", "", "Rex server address: socket path, unix:// URL, or host:port (default $REX_SERVER or the local socket)")
	pf.BoolVar(&g.noReload, "no-reload", false, "don't reload the Rex config after plugins change")
	pf.BoolVar(&g.plain, "plain", false, "print plain lines instead of opening the plugin window")
	pf.IntVarP(&g.parallel, "jobs", "j", 4, "how many plugins to work on at once")

	root.AddCommand(
		opCommand(g, ui.OpInstall, []string{"i"}, "Install missing plugins",
			"Clone plugins that are declared but not installed. A plugin with a lockfile entry gets the locked commit."),
		opCommand(g, ui.OpUpdate, []string{"up"}, "Update plugins to their newest commit or version",
			"Fetch and move each plugin to the newest commit of its branch, or the newest tag its version allows, then rewrite its lockfile entry. Local changes are never discarded."),
		opCommand(g, ui.OpRestore, nil, "Check out the commits recorded in the lockfile",
			"Check out each plugin's locked commit, installing it when missing. Refuses checkouts with local changes."),
		opCommand(g, ui.OpBuild, nil, "Run build steps",
			"Run the build step of plugins that declare one, even if it already ran for the locked commit."),
		outdatedCommand(g),
		listCommand(g),
		cleanCommand(g),
		doctorCommand(g),
		selfUpdateCommand(g),
	)

	if err := root.ExecuteContext(ctx); err != nil {
		if !errors.Is(err, ui.ErrFailed) {
			fmt.Fprintln(os.Stderr, "amber:", err)
		}
		return 1
	}
	return 0
}

// ui opens the plugin window, optionally starting op right away.
func (g *globals) ui(op ui.Op, target string, cleanLock bool) error {
	var c *conn
	defer func() {
		if c != nil {
			c.Close()
		}
	}()
	return ui.Run(ui.Options{
		Connect: func(ctx context.Context) (*ui.Session, error) {
			var err error
			c, err = g.connect(ctx)
			if err != nil {
				return nil, err
			}
			return c.session, nil
		},
		Op:        op,
		Target:    target,
		NoReload:  g.noReload,
		CleanLock: cleanLock,
		Version:   Version,
		Parallel:  g.parallel,
	})
}

func opCommand(g *globals, op ui.Op, aliases []string, short, long string) *cobra.Command {
	return &cobra.Command{
		Use:     string(op) + " [plugin]",
		Aliases: aliases,
		Short:   short,
		Long:    long,
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			target := ""
			if len(args) == 1 {
				target = args[0]
			}
			return g.run(cmd.Context(), op, target)
		},
	}
}

func outdatedCommand(g *globals) *cobra.Command {
	return &cobra.Command{
		Use:     "outdated [plugin]",
		Aliases: []string{"check"},
		Short:   "Show plugins with a newer commit or version",
		Long:    "Fetch each plugin and report what an update would change. Nothing is checked out and the lockfile is not touched.",
		Args:    cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			target := ""
			if len(args) == 1 {
				target = args[0]
			}
			return g.run(cmd.Context(), ui.OpCheck, target)
		},
	}
}

// run performs op in the plugin window, or with plain output when not on a terminal.
func (g *globals) run(ctx context.Context, op ui.Op, target string) error {
	if !g.plain && interactive() {
		return g.ui(op, target, false)
	}
	c, err := g.connect(ctx)
	if err != nil {
		return err
	}
	defer c.Close()
	return ui.RunPlain(ctx, os.Stdout, c.session, op, target, g.parallel, !g.noReload)
}
