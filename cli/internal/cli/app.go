package cli

import (
	"fmt"
	"net/http"

	"github.com/spf13/cobra"
)

type healthData struct {
	ProtocolVersion int  `json:"protocol_version"`
	AuthRequired    bool `json:"auth_required"`
	Reachable       bool `json:"reachable"`
}

func newAppCommand(rt *Runtime) *cobra.Command {
	command := &cobra.Command{Use: "app", Short: "Inspect the opted-in debug App"}
	command.AddCommand(newAppProbe(rt))
	return command
}

func newAppProbe(rt *Runtime) *cobra.Command {
	return &cobra.Command{
		Use:   "probe",
		Short: "Probe the App debug endpoint",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			_, selected, client, err := rt.Resolve(cmd.Context(), true)
			if err != nil {
				return err
			}
			var data healthData
			if _, err := client.DoJSON(cmd.Context(), http.MethodGet, "/v1/health", nil, 1<<20, &data); err != nil {
				return err
			}
			selectedDeviceID := ""
			if selected != nil {
				selectedDeviceID = selected.UDID
			}
			return rt.Success(data, metaFor(selected, rt.Elapsed()), formatHealth(data, selectedDeviceID))
		},
	}
}

func formatHealth(data healthData, selectedDeviceID string) string {
	reachability := "not reachable"
	if data.Reachable {
		reachability = "reachable"
	}
	authentication := "authentication not required"
	if data.AuthRequired {
		authentication = "authentication required"
	}
	location := ""
	if selectedDeviceID != "" {
		location = " on " + humanCell(selectedDeviceID)
	}
	return fmt.Sprintf("App %s%s (protocol %d, %s).\n", reachability, location, data.ProtocolVersion, authentication)
}
