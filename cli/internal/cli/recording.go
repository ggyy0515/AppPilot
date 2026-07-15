package cli

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"
	"github.com/yangy003/ap-ios-debug-system/internal/artifact"
	"github.com/yangy003/ap-ios-debug-system/internal/contract"
	"github.com/yangy003/ap-ios-debug-system/internal/protocol"
)

const recordingMaxBytes int64 = 500 << 20

var recordingContext = context.WithTimeout

type recordingResult struct {
	Path              string   `json:"path"`
	ByteCount         int64    `json:"byte_count"`
	MIME              string   `json:"mime"`
	SHA256            string   `json:"sha256"`
	NextCommands      []string `json:"next_commands"`
	RecordingID       string   `json:"recording_id"`
	DurationMS        int64    `json:"duration_ms"`
	DeviceFileDeleted bool     `json:"device_file_deleted"`
}

func newRecordingCommand(rt *Runtime) *cobra.Command {
	command := &cobra.Command{Use: "recording", Short: "Control and persist ReplayKit recordings"}
	command.AddCommand(newRecordingStatus(rt), newRecordingStart(rt), newRecordingStop(rt))
	return command
}

func newRecordingStatus(rt *Runtime) *cobra.Command {
	return &cobra.Command{
		Use: "status", Short: "Show the current recording state", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			_, selected, client, err := rt.Resolve(cmd.Context(), true)
			if err != nil {
				return err
			}
			status, err := protocol.NewRecording(client).Status(cmd.Context())
			if err != nil {
				return err
			}
			return rt.Success(status, metaFor(selected, rt.Elapsed()), fmt.Sprintf("Recording state: %s.\n", humanCell(status.State)))
		},
	}
}

func newRecordingStart(rt *Runtime) *cobra.Command {
	return &cobra.Command{
		Use: "start", Short: "Start a ReplayKit recording", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			_, selected, client, err := rt.Resolve(cmd.Context(), true)
			if err != nil {
				return err
			}
			ctx, cancel := recordingContext(cmd.Context(), 60*time.Second)
			defer cancel()
			started, err := protocol.NewRecording(client).Start(ctx)
			if err != nil {
				return err
			}
			return rt.Success(started, metaFor(selected, rt.Elapsed()), "Recording started.\n")
		},
	}
}

func newRecordingStop(rt *Runtime) *cobra.Command {
	var explicitOut string
	command := &cobra.Command{
		Use: "stop", Short: "Stop and persist a verified MP4 recording", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, selected, client, err := rt.Resolve(cmd.Context(), true)
			if err != nil {
				return err
			}
			ctx, cancel := recordingContext(cmd.Context(), 90*time.Second)
			defer cancel()
			service := protocol.NewRecording(client)
			stopped, err := service.Stop(ctx)
			if err != nil {
				return err
			}
			download, err := service.Open(ctx, stopped.RecordingID)
			if err != nil {
				return err
			}
			defer download.Body.Close()
			if download.ContentLength != stopped.ByteCount || download.SHA256 != stopped.SHA256 {
				return contract.New(contract.ArtifactChecksumMismatch, nil)
			}

			destination, err := artifact.Destination(cfg.OutputDir, explicitOut, "recording.mp4", rt.now())
			if err != nil {
				return err
			}
			info, err := artifact.Write(ctx, download.Body, artifact.WriteOptions{
				Destination: destination, MIME: "video/mp4", ExpectedSHA256: stopped.SHA256,
				MaxBytes: recordingMaxBytes, Validator: artifact.ValidateMP4,
			})
			if err != nil {
				return err
			}
			if err := download.Body.Close(); err != nil {
				_ = os.Remove(info.Path)
				return contract.New(contract.IOFailure, err)
			}
			info.NextCommands = []string{"open " + info.Path}
			deleted := service.Delete(ctx, stopped.RecordingID) == nil
			if !deleted {
				_, _ = fmt.Fprintln(cmd.ErrOrStderr(), "ap-ios-debug: warning: verified recording saved locally; device cleanup will retry through the App retention policy.")
			}
			result := recordingResult{
				Path: info.Path, ByteCount: info.ByteCount, MIME: info.MIME, SHA256: info.SHA256,
				NextCommands: info.NextCommands, RecordingID: stopped.RecordingID,
				DurationMS: stopped.DurationMS, DeviceFileDeleted: deleted,
			}
			return rt.Success(result, metaFor(selected, rt.Elapsed()), fmt.Sprintf("Recording saved to %s.\n", humanCell(info.Path)))
		},
	}
	command.Flags().StringVar(&explicitOut, "out", "", "write the MP4 to this path")
	return command
}
