package cli

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/scaffold"
)

func newAppScaffold(rt *Runtime) *cobra.Command {
	var into string
	var dryRun bool
	command := &cobra.Command{
		Use:   "scaffold",
		Short: "Plan or copy APIOSDebugKit into an App project",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			plan, err := scaffold.Plan(into, scaffold.NewLocator(rt.executablePath, rt.userHome))
			if err != nil {
				return err
			}
			result := plan.Result(true)
			if !dryRun {
				result, err = scaffold.Apply(plan)
				if err != nil {
					return err
				}
			}
			return rt.Success(result, metaFor(nil, rt.Elapsed()), formatScaffold(result))
		},
	}
	command.Flags().StringVar(&into, "into", "", "project root that receives DebugTools")
	command.Flags().BoolVar(&dryRun, "dry-run", false, "report create, unchanged, and conflict files without writing")
	_ = command.MarkFlagRequired("into")
	return command
}

func formatScaffold(result scaffold.ScaffoldResult) string {
	var output strings.Builder
	for _, file := range result.Files {
		_, _ = fmt.Fprintf(&output, "%s\t%s\n", file.Status, file.Path)
	}
	for _, step := range result.XcodeSteps {
		output.WriteString(step)
		output.WriteByte('\n')
	}
	return output.String()
}
