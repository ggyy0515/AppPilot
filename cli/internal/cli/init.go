package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	"github.com/yangy003/ios-debug-system/cli/internal/contract"
	"github.com/yangy003/ios-debug-system/cli/internal/scaffold"
)

func newInitCommand(rt *Runtime) *cobra.Command {
	var local bool
	command := &cobra.Command{
		Use:   "init",
		Short: "Create the project-local ios-debug configuration",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if !local {
				return contract.NewWithHint(contract.ConfigInvalid, nil, "Pass --local to manage only the current project's .ios-debug.toml.")
			}
			root := rt.workingDir
			if root == "" {
				var err error
				root, err = os.Getwd()
				if err != nil {
					return contract.New(contract.IOFailure, err)
				}
			}
			file, err := scaffold.InitLocal(root)
			if err != nil {
				return err
			}
			data := struct {
				Path   string `json:"path"`
				Status string `json:"status"`
			}{Path: file.Path, Status: file.Status}
			return rt.Success(data, metaFor(nil, rt.Elapsed()), fmt.Sprintf("%s\t%s\n", file.Status, file.Path))
		},
	}
	command.Flags().BoolVar(&local, "local", false, "manage only the current project's .ios-debug.toml")
	return command
}
