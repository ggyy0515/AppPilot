package artifact

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/yangy003/ios-debug-system/cli/internal/contract"
)

type Info struct {
	Path         string   `json:"path"`
	ByteCount    int64    `json:"byte_count"`
	MIME         string   `json:"mime"`
	SHA256       string   `json:"sha256"`
	NextCommands []string `json:"next_commands"`
}

type WriteOptions struct {
	Destination    string
	MIME           string
	ExpectedSHA256 string
	MaxBytes       int64
	Validator      func(string) error
}

var (
	createTempFile = os.CreateTemp
	removeFile     = os.Remove
)

func Write(ctx context.Context, src io.Reader, options WriteOptions) (info Info, err error) {
	if options.Destination == "" || options.MaxBytes < 0 {
		return info, contract.New(contract.ConfigInvalid, nil)
	}
	absoluteDestination, absErr := filepath.Abs(options.Destination)
	if absErr != nil {
		return info, contract.New(contract.IOFailure, absErr)
	}
	directory := filepath.Dir(absoluteDestination)
	if err = os.MkdirAll(directory, 0o700); err != nil {
		return info, contract.New(contract.IOFailure, err)
	}
	temp, err := createTempFile(directory, ".ios-debug-*")
	if err != nil {
		return info, contract.New(contract.IOFailure, err)
	}
	tempName := temp.Name()
	tempNeedsRemoval := true
	defer func() {
		_ = temp.Close()
		if tempNeedsRemoval {
			_ = removeFile(tempName)
		}
	}()
	if err = temp.Chmod(0o600); err != nil {
		return info, contract.New(contract.IOFailure, err)
	}

	hash := sha256.New()
	limited := io.LimitReader(src, options.MaxBytes+1)
	written, copyErr := io.Copy(io.MultiWriter(temp, hash), &contextReader{ctx: ctx, reader: limited})
	if copyErr != nil {
		var stable *contract.Error
		if errors.As(copyErr, &stable) {
			return info, copyErr
		}
		if errors.Is(copyErr, context.Canceled) || errors.Is(copyErr, context.DeadlineExceeded) {
			return info, contract.New(contract.RequestTimeout, copyErr)
		}
		return info, contract.New(contract.IOFailure, copyErr)
	}
	if written > options.MaxBytes {
		return info, contract.New(contract.ArtifactTooLarge, nil)
	}
	if err = temp.Sync(); err != nil {
		return info, contract.New(contract.IOFailure, err)
	}
	if err = temp.Close(); err != nil {
		return info, contract.New(contract.IOFailure, err)
	}

	actualSHA256 := hex.EncodeToString(hash.Sum(nil))
	if subtle.ConstantTimeCompare([]byte(actualSHA256), []byte(options.ExpectedSHA256)) != 1 {
		return info, contract.New(contract.ArtifactChecksumMismatch, nil)
	}
	if options.Validator != nil {
		if err = options.Validator(tempName); err != nil {
			return info, err
		}
	}
	if err = linkNoReplace(tempName, absoluteDestination); err != nil {
		return info, contract.New(contract.IOFailure, err)
	}
	// The successful link is the commit point. Temporary-name cleanup cannot
	// turn an already committed artifact into a reported failure.
	removeErr := removeFile(tempName)
	if removeErr == nil || errors.Is(removeErr, os.ErrNotExist) {
		tempNeedsRemoval = false
	}
	return Info{Path: absoluteDestination, ByteCount: written, MIME: options.MIME, SHA256: actualSHA256}, nil
}

func Destination(outputDir, explicitOut, basename string, now time.Time) (string, error) {
	if basename == "" {
		return "", contract.New(contract.ConfigInvalid, nil)
	}
	result := explicitOut
	if result == "" {
		if outputDir == "" {
			return "", contract.New(contract.ConfigInvalid, nil)
		}
		stamp := now.UTC().Format("20060102T150405.000000000Z")
		result = filepath.Join(outputDir, stamp, basename)
	}
	absolute, err := filepath.Abs(result)
	if err != nil {
		return "", contract.New(contract.IOFailure, err)
	}
	return absolute, nil
}

func linkNoReplace(source, destination string) error {
	info, err := os.Lstat(source)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return errors.New("artifact temporary file is not a regular file")
	}
	if err := os.Link(source, destination); err != nil {
		return err
	}
	return nil
}

type contextReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r *contextReader) Read(buffer []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(buffer)
}
