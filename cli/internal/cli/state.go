package cli

import (
	"bytes"
	"encoding/json"

	"github.com/spf13/cobra"
	"github.com/yangy003/ap-ios-debug-system/internal/contract"
	"github.com/yangy003/ap-ios-debug-system/internal/protocol"
)

func newStateCommand(rt *Runtime) *cobra.Command {
	command := &cobra.Command{Use: "state", Short: "Inspect the App Debug state"}
	command.AddCommand(newStateGet(rt))
	return command
}

func newStateGet(rt *Runtime) *cobra.Command {
	return &cobra.Command{
		Use:   "get",
		Short: "Get the current App Debug state",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			_, selected, client, err := rt.Resolve(cmd.Context(), true)
			if err != nil {
				return err
			}
			data, err := protocol.NewState(client).Get(cmd.Context())
			if err != nil {
				return err
			}
			text, err := formatState(data)
			if err != nil {
				return err
			}
			return rt.Success(data, metaFor(selected, rt.Elapsed()), text)
		},
	}
}

func formatState(data json.RawMessage) (string, error) {
	var output bytes.Buffer
	output.WriteString("App state:\n")
	encoder := json.NewEncoder(&output)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(data); err != nil {
		return "", contract.New(contract.ProtocolMismatch, err)
	}
	return output.String(), nil
}
