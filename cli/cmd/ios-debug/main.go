package main

import (
	"os"

	"github.com/yangy003/ios-debug-system/cli/internal/buildinfo"
	"github.com/yangy003/ios-debug-system/cli/internal/cli"
)

func main() {
	os.Exit(cli.Execute(os.Args[1:], os.Stdout, os.Stderr, cli.Dependencies{Version: buildinfo.Version}))
}
