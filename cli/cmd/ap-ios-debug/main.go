package main

import (
	"os"

	"github.com/yangy003/ap-ios-debug-system/internal/buildinfo"
	"github.com/yangy003/ap-ios-debug-system/internal/cli"
)

func main() {
	deps := cli.NewProductionDependencies(os.Stdout, os.Stderr)
	deps.Version = buildinfo.Version
	os.Exit(cli.Execute(os.Args[1:], os.Stdout, os.Stderr, deps))
}
