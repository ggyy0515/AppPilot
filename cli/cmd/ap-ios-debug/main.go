package main

import (
	"os"

	"github.com/ggyy0515/AppPilot/internal/buildinfo"
	"github.com/ggyy0515/AppPilot/internal/cli"
)

func main() {
	deps := cli.NewProductionDependencies(os.Stdout, os.Stderr)
	deps.Version = buildinfo.Version
	os.Exit(cli.Execute(os.Args[1:], os.Stdout, os.Stderr, deps))
}
