package cli

import (
	"context"
	"fmt"
	"strings"

	"github.com/spf13/cobra"
	"github.com/yangy003/ap-ios-debug-system/internal/config"
	"github.com/yangy003/ap-ios-debug-system/internal/contract"
	"github.com/yangy003/ap-ios-debug-system/internal/doctor"
	"github.com/yangy003/ap-ios-debug-system/internal/scaffold"
)

func newDoctorCommand(rt *Runtime, deps doctor.Dependencies, version string) *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Check local iOS debugging prerequisites",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if deps.Version == "" {
				deps.Version = version
			}
			if deps.ConfigLoader == nil {
				deps.ConfigLoader = func(ctx context.Context, _ config.LoadOptions) (config.Config, error) {
					return rt.loadConfig(ctx)
				}
			}
			if deps.DeviceDiscoverer == nil {
				deps.DeviceDiscoverer = rt.devices
			}
			if deps.TemplateLocator == nil {
				deps.TemplateLocator = scaffold.NewLocator(rt.executablePath, rt.userHome)
			}
			if deps.ExecutablePath == "" {
				deps.ExecutablePath = rt.executablePath
			}
			report, err := doctor.Run(cmd.Context(), deps)
			if emitErr := rt.Success(report, contract.Meta{ProtocolVersion: 1, DurationMS: rt.Elapsed().Milliseconds()}, formatDoctorReport(report)); emitErr != nil {
				return emitErr
			}
			if err != nil {
				return &reportedCommandError{err: err}
			}
			return nil
		},
	}
}

func formatDoctorReport(report doctor.Report) string {
	var output strings.Builder
	health := "unhealthy"
	if report.Healthy {
		health = "healthy"
	}
	fmt.Fprintf(&output, "Doctor: %s (ap-ios-debug %s)\n", health, humanCell(report.Version))
	for _, check := range report.Checks {
		fmt.Fprintf(&output, "%s: %s - %s", check.Name, check.Status, humanCell(check.Message))
		if check.Hint != "" {
			fmt.Fprintf(&output, " (%s)", humanCell(check.Hint))
		}
		output.WriteByte('\n')
	}
	return output.String()
}
