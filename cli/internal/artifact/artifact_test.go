package artifact_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ios-debug-system/cli/internal/artifact"
	"github.com/yangy003/ios-debug-system/cli/internal/contract"
)

func TestWriteIsAtomicPrivateAndChecksummed(t *testing.T) {
	payload := validPNG(t)
	destination := filepath.Join(t.TempDir(), "shot.png")
	info, err := artifact.Write(context.Background(), bytes.NewReader(payload), artifact.WriteOptions{
		Destination: destination, MIME: "image/png", ExpectedSHA256: sha256Hex(payload), MaxBytes: 25 << 20, Validator: artifact.ValidatePNG,
	})
	require.NoError(t, err)
	absolute, err := filepath.Abs(destination)
	require.NoError(t, err)
	require.Equal(t, absolute, info.Path)
	require.Equal(t, int64(len(payload)), info.ByteCount)
	require.Equal(t, "image/png", info.MIME)
	require.Equal(t, sha256Hex(payload), info.SHA256)
	stat, err := os.Stat(destination)
	require.NoError(t, err)
	require.Equal(t, fs.FileMode(0o600), stat.Mode().Perm())
	require.Empty(t, tempArtifacts(t, filepath.Dir(destination)))
}

func TestWriteRemovesTempAndDestinationOnChecksumFailure(t *testing.T) {
	payload := validPNG(t)
	destination := filepath.Join(t.TempDir(), "shot.png")
	_, err := artifact.Write(context.Background(), bytes.NewReader(payload), artifact.WriteOptions{
		Destination: destination, MIME: "image/png", ExpectedSHA256: strings.Repeat("0", 64), MaxBytes: 25 << 20, Validator: artifact.ValidatePNG,
	})
	require.Equal(t, contract.ArtifactChecksumMismatch, contract.CodeOf(err))
	require.NoFileExists(t, destination)
	require.Empty(t, tempArtifacts(t, filepath.Dir(destination)))
}

func TestWriteRejectsOversizeAndInvalidPNGWithoutArtifacts(t *testing.T) {
	for _, testCase := range []struct {
		name      string
		payload   []byte
		max       int64
		validator func(string) error
		code      contract.Code
	}{
		{name: "max plus one", payload: []byte("1234"), max: 3, code: contract.ArtifactTooLarge},
		{name: "invalid png", payload: []byte("not a png"), max: 100, validator: artifact.ValidatePNG, code: contract.ScreenshotFailed},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			directory := t.TempDir()
			destination := filepath.Join(directory, "shot.png")
			_, err := artifact.Write(context.Background(), bytes.NewReader(testCase.payload), artifact.WriteOptions{
				Destination: destination, MIME: "image/png", ExpectedSHA256: sha256Hex(testCase.payload), MaxBytes: testCase.max, Validator: testCase.validator,
			})
			require.Equal(t, testCase.code, contract.CodeOf(err))
			require.NoFileExists(t, destination)
			require.Empty(t, tempArtifacts(t, directory))
		})
	}
}

func TestWriteRefusesExistingOutputAndInvalidParent(t *testing.T) {
	t.Run("existing output", func(t *testing.T) {
		payload := validPNG(t)
		destination := filepath.Join(t.TempDir(), "shot.png")
		require.NoError(t, os.WriteFile(destination, []byte("keep"), 0o644))

		_, err := artifact.Write(context.Background(), bytes.NewReader(payload), artifact.WriteOptions{
			Destination: destination, MIME: "image/png", ExpectedSHA256: sha256Hex(payload), MaxBytes: 25 << 20, Validator: artifact.ValidatePNG,
		})
		require.Equal(t, contract.IOFailure, contract.CodeOf(err))
		require.FileExists(t, destination)
		contents, readErr := os.ReadFile(destination)
		require.NoError(t, readErr)
		require.Equal(t, "keep", string(contents))
		require.Empty(t, tempArtifacts(t, filepath.Dir(destination)))
	})

	t.Run("parent is not a directory", func(t *testing.T) {
		parent := filepath.Join(t.TempDir(), "not-directory")
		require.NoError(t, os.WriteFile(parent, []byte("x"), 0o600))
		_, err := artifact.Write(context.Background(), strings.NewReader("x"), artifact.WriteOptions{
			Destination: filepath.Join(parent, "shot.png"), MIME: "image/png", ExpectedSHA256: sha256Hex([]byte("x")), MaxBytes: 1,
		})
		require.Equal(t, contract.IOFailure, contract.CodeOf(err))
	})
}

func TestWritePreservesStableReaderErrors(t *testing.T) {
	for _, code := range []contract.Code{
		contract.RequestTimeout,
		contract.TransportFailure,
		contract.ProtocolMismatch,
	} {
		t.Run(string(code), func(t *testing.T) {
			directory := t.TempDir()
			destination := filepath.Join(directory, "shot.png")
			cause := errors.New("reader stopped")
			readerErr := contract.New(code, cause)
			_, err := artifact.Write(context.Background(), &partialErrorReader{
				payload: []byte("partial"), err: readerErr,
			}, artifact.WriteOptions{
				Destination: destination, MIME: "image/png", ExpectedSHA256: strings.Repeat("0", 64), MaxBytes: 25 << 20,
			})

			require.Equal(t, code, contract.CodeOf(err))
			require.ErrorIs(t, err, cause)
			require.NoFileExists(t, destination)
			require.Empty(t, tempArtifacts(t, directory))
		})
	}
}

func TestWriteMapsOrdinaryReaderErrorsToIOFailure(t *testing.T) {
	directory := t.TempDir()
	destination := filepath.Join(directory, "shot.png")
	cause := errors.New("local reader failed")
	_, err := artifact.Write(context.Background(), &partialErrorReader{
		payload: []byte("partial"), err: cause,
	}, artifact.WriteOptions{
		Destination: destination, MIME: "application/octet-stream", ExpectedSHA256: strings.Repeat("0", 64), MaxBytes: 25 << 20,
	})

	require.Equal(t, contract.IOFailure, contract.CodeOf(err))
	require.ErrorIs(t, err, cause)
	require.NoFileExists(t, destination)
	require.Empty(t, tempArtifacts(t, directory))
}

func TestWriteMapsContextCancellationToRequestTimeout(t *testing.T) {
	for _, testCase := range []struct {
		name  string
		ctx   func(t *testing.T) context.Context
		cause error
	}{
		{
			name: "canceled before transfer",
			ctx: func(t *testing.T) context.Context {
				ctx, cancel := context.WithCancel(context.Background())
				t.Cleanup(cancel)
				cancel()
				return ctx
			},
			cause: context.Canceled,
		},
		{
			name: "deadline exceeded before transfer",
			ctx: func(t *testing.T) context.Context {
				ctx, cancel := context.WithDeadline(context.Background(), time.Unix(0, 0))
				t.Cleanup(cancel)
				return ctx
			},
			cause: context.DeadlineExceeded,
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			directory := t.TempDir()
			destination := filepath.Join(directory, "shot.png")
			_, err := artifact.Write(testCase.ctx(t), strings.NewReader("payload"), artifact.WriteOptions{
				Destination: destination, MIME: "application/octet-stream", ExpectedSHA256: strings.Repeat("0", 64), MaxBytes: 25 << 20,
			})

			require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
			require.Equal(t, 4, contract.ExitCode(err))
			require.ErrorIs(t, err, testCase.cause)
			require.NoFileExists(t, destination)
			require.Empty(t, tempArtifacts(t, directory))
		})
	}
}

func TestWriteMapsMidstreamContextCancellationToRequestTimeout(t *testing.T) {
	directory := t.TempDir()
	destination := filepath.Join(directory, "shot.png")
	ctx, cancel := context.WithCancel(context.Background())
	reader := &cancelAfterFirstRead{
		payload: []byte("partial payload"),
		cancel:  cancel,
	}

	_, err := artifact.Write(ctx, reader, artifact.WriteOptions{
		Destination: destination, MIME: "application/octet-stream", ExpectedSHA256: strings.Repeat("0", 64), MaxBytes: 25 << 20,
	})

	require.Equal(t, contract.RequestTimeout, contract.CodeOf(err))
	require.Equal(t, 4, contract.ExitCode(err))
	require.ErrorIs(t, err, context.Canceled)
	require.NoFileExists(t, destination)
	require.Empty(t, tempArtifacts(t, directory))
}

func TestWritePrefersKnownReaderErrorOverTimeoutCause(t *testing.T) {
	directory := t.TempDir()
	destination := filepath.Join(directory, "shot.png")
	readerErr := contract.New(contract.TransportFailure, context.DeadlineExceeded)

	_, err := artifact.Write(context.Background(), &partialErrorReader{err: readerErr}, artifact.WriteOptions{
		Destination: destination, MIME: "application/octet-stream", ExpectedSHA256: strings.Repeat("0", 64), MaxBytes: 25 << 20,
	})

	require.Equal(t, contract.TransportFailure, contract.CodeOf(err))
	require.Equal(t, 4, contract.ExitCode(err))
	require.ErrorIs(t, err, context.DeadlineExceeded)
	require.NoFileExists(t, destination)
	require.Empty(t, tempArtifacts(t, directory))
}

func TestWriteConcurrentNoReplaceHasExactlyOneWinner(t *testing.T) {
	const writerCount = 32
	directory := t.TempDir()
	destination := filepath.Join(directory, "shot.png")
	var ready sync.WaitGroup
	ready.Add(writerCount)
	release := make(chan struct{})
	go func() {
		ready.Wait()
		close(release)
	}()

	type result struct {
		payload []byte
		err     error
	}
	results := make(chan result, writerCount)
	for index := 0; index < writerCount; index++ {
		payload := []byte(fmt.Sprintf("writer-%02d", index))
		go func() {
			_, err := artifact.Write(context.Background(), bytes.NewReader(payload), artifact.WriteOptions{
				Destination:    destination,
				MIME:           "application/octet-stream",
				ExpectedSHA256: sha256Hex(payload),
				MaxBytes:       int64(len(payload)),
				Validator: func(string) error {
					ready.Done()
					<-release
					return nil
				},
			})
			results <- result{payload: payload, err: err}
		}()
	}

	winners := make([][]byte, 0, 1)
	for range writerCount {
		result := <-results
		if result.err == nil {
			winners = append(winners, result.payload)
			continue
		}
		require.Equal(t, contract.IOFailure, contract.CodeOf(result.err))
		require.ErrorIs(t, result.err, os.ErrExist)
	}
	require.Len(t, winners, 1)
	require.FileExists(t, destination)
	contents, err := os.ReadFile(destination)
	require.NoError(t, err)
	require.Equal(t, winners[0], contents)
	require.Empty(t, tempArtifacts(t, directory))
}

func TestWriteRefusesDestinationCreatedAtCommitWithoutFollowingSymlink(t *testing.T) {
	for _, testCase := range []struct {
		name   string
		create func(t *testing.T, destination string)
		check  func(t *testing.T, destination string)
	}{
		{
			name: "regular file",
			create: func(t *testing.T, destination string) {
				require.NoError(t, os.WriteFile(destination, []byte("keep"), 0o644))
			},
			check: func(t *testing.T, destination string) {
				contents, err := os.ReadFile(destination)
				require.NoError(t, err)
				require.Equal(t, []byte("keep"), contents)
			},
		},
		{
			name: "symbolic link",
			create: func(t *testing.T, destination string) {
				target := filepath.Join(filepath.Dir(destination), "target.png")
				require.NoError(t, os.WriteFile(target, []byte("keep"), 0o644))
				require.NoError(t, os.Symlink(target, destination))
			},
			check: func(t *testing.T, destination string) {
				info, err := os.Lstat(destination)
				require.NoError(t, err)
				require.NotZero(t, info.Mode()&os.ModeSymlink)
				contents, err := os.ReadFile(destination)
				require.NoError(t, err)
				require.Equal(t, []byte("keep"), contents)
			},
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			payload := []byte("new artifact")
			directory := t.TempDir()
			destination := filepath.Join(directory, "shot.png")
			atCommit := make(chan struct{})
			release := make(chan struct{})
			result := make(chan error, 1)
			go func() {
				_, err := artifact.Write(context.Background(), bytes.NewReader(payload), artifact.WriteOptions{
					Destination:    destination,
					MIME:           "application/octet-stream",
					ExpectedSHA256: sha256Hex(payload),
					MaxBytes:       int64(len(payload)),
					Validator: func(string) error {
						close(atCommit)
						<-release
						return nil
					},
				})
				result <- err
			}()

			<-atCommit
			testCase.create(t, destination)
			close(release)
			err := <-result
			require.Equal(t, contract.IOFailure, contract.CodeOf(err))
			require.ErrorIs(t, err, os.ErrExist)
			testCase.check(t, destination)
			require.Empty(t, tempArtifacts(t, directory))
		})
	}
}

func TestDestinationUsesExplicitPathOrDefaultUTCDirectory(t *testing.T) {
	now := time.Date(2026, time.July, 14, 8, 9, 10, 123000000, time.FixedZone("CST", 8*60*60))
	outputDir := t.TempDir()

	got, err := artifact.Destination(outputDir, "", "screenshot.png", now)
	require.NoError(t, err)
	require.Equal(t, filepath.Join(outputDir, "20260714T000910.123000000Z", "screenshot.png"), got)
	require.True(t, filepath.IsAbs(got))

	explicit := filepath.Join(t.TempDir(), "custom.png")
	got, err = artifact.Destination(outputDir, explicit, "screenshot.png", now)
	require.NoError(t, err)
	require.Equal(t, explicit, got)
}

func validPNG(t *testing.T) []byte {
	t.Helper()
	var output bytes.Buffer
	img := image.NewRGBA(image.Rect(0, 0, 1, 1))
	img.Set(0, 0, color.RGBA{R: 1, G: 2, B: 3, A: 255})
	require.NoError(t, png.Encode(&output, img))
	return output.Bytes()
}

func sha256Hex(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

func tempArtifacts(t *testing.T, directory string) []string {
	t.Helper()
	matches, err := filepath.Glob(filepath.Join(directory, ".ios-debug-*"))
	require.NoError(t, err)
	return matches
}

type partialErrorReader struct {
	payload []byte
	err     error
	done    bool
}

type cancelAfterFirstRead struct {
	payload []byte
	cancel  context.CancelFunc
	done    bool
}

func (r *cancelAfterFirstRead) Read(buffer []byte) (int, error) {
	if r.done {
		return 0, io.EOF
	}
	r.done = true
	written := copy(buffer, r.payload)
	r.cancel()
	return written, nil
}

func (r *partialErrorReader) Read(buffer []byte) (int, error) {
	if r.done {
		return 0, r.err
	}
	r.done = true
	return copy(buffer, r.payload), r.err
}
