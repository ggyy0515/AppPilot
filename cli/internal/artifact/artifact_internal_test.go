package artifact

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
)

func TestWriteReportsUnwritableDirectoryDeterministically(t *testing.T) {
	original := createTempFile
	createTempFile = func(string, string) (*os.File, error) {
		return nil, fs.ErrPermission
	}
	t.Cleanup(func() { createTempFile = original })

	directory := t.TempDir()
	destination := filepath.Join(directory, "shot.png")
	_, err := Write(context.Background(), strings.NewReader("x"), WriteOptions{
		Destination:    destination,
		MIME:           "application/octet-stream",
		ExpectedSHA256: sha256HexForInternalTest([]byte("x")),
		MaxBytes:       1,
	})

	require.Equal(t, contract.IOFailure, contract.CodeOf(err))
	require.True(t, errors.Is(err, fs.ErrPermission))
	require.NoFileExists(t, destination)
}

func TestWriteCommitSucceedsWhenFirstTemporaryUnlinkFails(t *testing.T) {
	original := removeFile
	removeCalls := 0
	removeFile = func(path string) error {
		removeCalls++
		if removeCalls == 1 {
			return fs.ErrPermission
		}
		return os.Remove(path)
	}
	t.Cleanup(func() { removeFile = original })

	payload := []byte("committed artifact")
	directory := t.TempDir()
	destination := filepath.Join(directory, "shot.png")
	info, err := Write(context.Background(), bytes.NewReader(payload), WriteOptions{
		Destination:    destination,
		MIME:           "application/octet-stream",
		ExpectedSHA256: sha256HexForInternalTest(payload),
		MaxBytes:       int64(len(payload)),
	})

	require.NoError(t, err)
	require.Equal(t, int64(len(payload)), info.ByteCount)
	contents, readErr := os.ReadFile(destination)
	require.NoError(t, readErr)
	require.Equal(t, payload, contents)
	require.GreaterOrEqual(t, removeCalls, 2)
	matches, globErr := filepath.Glob(filepath.Join(directory, ".ap-ios-debug-*"))
	require.NoError(t, globErr)
	require.Empty(t, matches)
}

func sha256HexForInternalTest(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}
