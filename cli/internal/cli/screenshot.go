package cli

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"
	"github.com/yangy003/ap-ios-debug-system/internal/artifact"
	"github.com/yangy003/ap-ios-debug-system/internal/contract"
	"github.com/yangy003/ap-ios-debug-system/internal/protocol"
)

const screenshotMaxBytes int64 = 25 << 20

type screenshotResult struct {
	artifact.Info
	protocol.ScreenshotMeta
}

func newScreenshotCommand(rt *Runtime) *cobra.Command {
	command := &cobra.Command{Use: "screenshot", Short: "Capture the App's foreground window"}
	command.AddCommand(newScreenshotCapture(rt))
	return command
}

func newScreenshotCapture(rt *Runtime) *cobra.Command {
	var explicitOut string
	command := &cobra.Command{
		Use:   "capture",
		Short: "Capture and persist a verified PNG screenshot",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, selected, client, err := rt.Resolve(cmd.Context(), true)
			if err != nil {
				return err
			}
			response, screenshotMeta, err := protocol.NewScreenshot(client).Capture(cmd.Context())
			if err != nil {
				return err
			}
			defer response.Body.Close()

			destination, err := artifact.Destination(cfg.OutputDir, explicitOut, "screenshot.png", rt.now())
			if err != nil {
				return err
			}
			info, err := artifact.Write(cmd.Context(), response.Body, artifact.WriteOptions{
				Destination: destination, MIME: "image/png", ExpectedSHA256: response.SHA256,
				MaxBytes: screenshotMaxBytes, Validator: artifact.ValidatePNG,
			})
			if err != nil {
				if contract.CodeOf(err) == contract.IOFailure && errors.Is(err, io.ErrUnexpectedEOF) {
					return contract.New(contract.ProtocolMismatch, err)
				}
				return err
			}
			if response.ContentLength < 0 || response.ContentLength != info.ByteCount {
				_ = os.Remove(info.Path)
				return contract.New(contract.ProtocolMismatch, nil)
			}

			if cfg.Transport == "tcp" {
				info.NextCommands = []string{fmt.Sprintf("ap-ios-debug --json state get --transport tcp --tcp-host %s", cfg.TCPHost)}
			} else {
				info.NextCommands = []string{fmt.Sprintf("ap-ios-debug --json state get --device %s", selected.UDID)}
			}
			result := screenshotResult{Info: info, ScreenshotMeta: screenshotMeta}
			return rt.Success(result, metaFor(selected, rt.Elapsed()), fmt.Sprintf("Screenshot saved to %s.\n", humanCell(info.Path)))
		},
	}
	command.Flags().StringVar(&explicitOut, "out", "", "write the PNG to this path")
	return command
}
