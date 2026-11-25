package main

import (
	"os"

	"github.com/rawnly/amber/cli/internal/cli"
)

func main() {
	os.Exit(cli.Execute())
}
