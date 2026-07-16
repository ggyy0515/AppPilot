package cli

import (
	"fmt"
	"strings"
	"unicode"

	"github.com/ggyy0515/AppPilot/internal/contract"
	"github.com/ggyy0515/AppPilot/internal/device"
	"github.com/spf13/cobra"
)

func newDevicesCommand(rt *Runtime) *cobra.Command {
	command := &cobra.Command{Use: "devices", Short: "Discover physical iOS devices"}
	command.AddCommand(newDevicesList(rt), newDevicesResolve(rt))
	return command
}

func newDevicesList(rt *Runtime) *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List physical iOS devices",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			devices, err := rt.devices.List(cmd.Context())
			if err != nil {
				return err
			}
			return rt.Success(struct {
				Devices []device.Device `json:"devices"`
			}{Devices: devices}, contract.Meta{ProtocolVersion: 1, DurationMS: rt.Elapsed().Milliseconds()}, formatDeviceList(devices))
		},
	}
}

func newDevicesResolve(rt *Runtime) *cobra.Command {
	var name string
	command := &cobra.Command{
		Use:   "resolve",
		Short: "Resolve one available device by exact name",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if name == "" {
				return contract.New(contract.ConfigInvalid, nil)
			}
			selected, err := rt.devices.Resolve(cmd.Context(), device.Selector{Name: name})
			if err != nil {
				return err
			}
			return rt.Success(struct {
				Device device.Device `json:"device"`
			}{Device: selected}, metaFor(&selected, rt.Elapsed()), formatResolvedDevice(selected))
		},
	}
	command.Flags().StringVar(&name, "name", "", "exact device name")
	return command
}

func formatDeviceList(devices []device.Device) string {
	var output strings.Builder
	output.WriteString("UDID\tNAME\tOS VERSION\tSTATUS\n")
	for _, current := range devices {
		status := "unavailable"
		if current.Available {
			status = "available"
		}
		fmt.Fprintf(&output, "%s\t%s\t%s\t%s\n", humanCell(current.UDID), humanCell(current.Name), humanCell(current.OSVersion), status)
	}
	return output.String()
}

func formatResolvedDevice(selected device.Device) string {
	status := "unavailable"
	if selected.Available {
		status = "available"
	}
	return fmt.Sprintf("Device: %s (%s), iOS %s, %s.\n", humanCell(selected.Name), humanCell(selected.UDID), humanCell(selected.OSVersion), status)
}

func humanCell(value string) string {
	previousWasControl := false
	return strings.Map(func(character rune) rune {
		if unicode.IsControl(character) {
			if previousWasControl {
				return -1
			}
			previousWasControl = true
			return ' '
		}
		previousWasControl = false
		return character
	}, value)
}
