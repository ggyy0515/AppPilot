package scaffold

import (
	"io/fs"
	"os"
	"path/filepath"

	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
)

type Locator interface {
	Locate() (string, error)
}

type locator struct {
	executablePath string
	userHome       string
}

func NewLocator(executablePath, userHome string) Locator {
	return locator{executablePath: executablePath, userHome: userHome}
}

func (l locator) Locate() (string, error) {
	if l.executablePath == "" || !filepath.IsAbs(l.executablePath) || l.userHome == "" || !filepath.IsAbs(l.userHome) {
		return "", contract.New(contract.IOFailure, fs.ErrInvalid)
	}
	candidates := []string{filepath.Join(l.userHome, ".local", "share", "ap-ios-debug", "ap-ios-debug-kit")}
	for directory := filepath.Dir(l.executablePath); ; directory = filepath.Dir(directory) {
		candidates = append(candidates, filepath.Join(directory, "swift", "ap-ios-debug-kit"))
		parent := filepath.Dir(directory)
		if parent == directory {
			break
		}
	}
	for _, candidate := range candidates {
		if regular(filepath.Join(candidate, "Package.swift")) && regular(filepath.Join(candidate, "Templates", "APIOSDebugBootstrap.swift")) {
			return candidate, nil
		}
	}
	return "", contract.NewWithHint(contract.IOFailure, nil, "Run make install-local or execute the repository build from its build directory.")
}

func regular(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.Mode().IsRegular()
}
