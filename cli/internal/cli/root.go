// Package cli wires Amber's commands.
package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

// Version is set at build time with -ldflags "-X github.com/rawnly/amber/cli/internal/cli.Version=v1.2.3".
var Version = "dev"

// Execute runs the command line and returns the exit code.
func Execute() int {
	root := &cobra.Command{
		Use:           "amber",
		Short:         "Plugin manager for Rex",
		Version:       Version,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "amber:", err)
		return 1
	}
	return 0
}
