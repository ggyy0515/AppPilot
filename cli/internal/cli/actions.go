package cli

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/protocol"
)

func newActionsCommand(rt *Runtime) *cobra.Command {
	command := &cobra.Command{Use: "actions", Short: "List and activate registered Debug actions"}
	command.AddCommand(newActionsList(rt), newActionsActivate(rt))
	return command
}

func newActionsList(rt *Runtime) *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List the currently registered Debug actions",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			_, selected, client, err := rt.Resolve(cmd.Context(), true)
			if err != nil {
				return err
			}
			data, err := protocol.NewActions(client).List(cmd.Context())
			if err != nil {
				return err
			}
			return rt.Success(data, metaFor(selected, rt.Elapsed()), formatActions(data))
		},
	}
}

func newActionsActivate(rt *Runtime) *cobra.Command {
	var dryRun bool
	command := &cobra.Command{
		Use:   "activate <identifier>",
		Short: "Validate and activate one registered Debug action",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			_, selected, client, err := rt.Resolve(cmd.Context(), true)
			if err != nil {
				return err
			}
			service := protocol.NewActions(client)
			action, err := service.Validate(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			if dryRun {
				data := struct {
					DryRun bool            `json:"dry_run"`
					Action protocol.Action `json:"action"`
				}{DryRun: true, Action: action}
				return rt.Success(data, metaFor(selected, rt.Elapsed()), fmt.Sprintf("Action %s is enabled (%s); no activation was sent.\n", humanCell(action.Identifier), humanCell(action.Role)))
			}
			activated, err := service.Activate(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			if activated.Generation != action.Generation {
				return contract.New(contract.ProtocolMismatch, nil)
			}
			activated.Role = action.Role
			return rt.Success(activated, metaFor(selected, rt.Elapsed()), fmt.Sprintf("Activated %s (%s).\n", humanCell(activated.Identifier), humanCell(activated.Role)))
		},
	}
	command.Flags().BoolVar(&dryRun, "dry-run", false, "validate the action without activating it")
	return command
}

func formatActions(data protocol.ActionsData) string {
	var output strings.Builder
	output.WriteString("IDENTIFIER\tROLE\tENABLED\tDESCRIPTION\n")
	for _, action := range data.Actions {
		_, _ = fmt.Fprintf(&output, "%s\t%s\t%t\t%s\n", humanCell(action.Identifier), humanCell(action.Role), action.Enabled, humanCell(action.Description))
	}
	return output.String()
}
