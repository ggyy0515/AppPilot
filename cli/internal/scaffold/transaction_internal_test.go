package scaffold

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ios-debug-system/cli/internal/contract"
)

func TestCanonicalValidationPathOnlyAllowsExactTrustedDarwinAliases(t *testing.T) {
	tests := []struct {
		name    string
		path    string
		trusted func(string, string) bool
		want    string
	}{
		{name: "trusted tmp", path: "/tmp/project", trusted: func(alias, target string) bool {
			return alias == "/tmp" && target == "/private/tmp"
		}, want: "/private/tmp/project"},
		{name: "trusted var", path: "/var/folders/project", trusted: func(alias, target string) bool {
			return alias == "/var" && target == "/private/var"
		}, want: "/private/var/folders/project"},
		{name: "untrusted replacement", path: "/tmp/project", trusted: func(string, string) bool { return false }, want: "/tmp/project"},
		{name: "component lookalike", path: "/tmp-evil/project", trusted: func(string, string) bool { return true }, want: "/tmp-evil/project"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			require.Equal(t, test.want, canonicalValidationPathWith(test.path, "darwin", test.trusted))
		})
	}
	require.Equal(t, "/tmp/project", canonicalValidationPathWith("/tmp/project", runtime.GOOS+"-not-darwin", func(string, string) bool { return true }))
}

func TestTrustedDarwinSystemAliasRejectsMaliciousReplacement(t *testing.T) {
	symlink := func(string) (os.FileMode, uint32, error) { return os.ModeSymlink, 0, nil }
	resolveExpected := func(string) (string, error) { return "/private/tmp", nil }
	require.True(t, trustedDarwinSystemAliasWith("/tmp", "/private/tmp", symlink, resolveExpected))

	tests := []struct {
		name    string
		stat    func(string) (os.FileMode, uint32, error)
		resolve func(string) (string, error)
	}{
		{name: "non-root owner", stat: func(string) (os.FileMode, uint32, error) { return os.ModeSymlink, 501, nil }, resolve: resolveExpected},
		{name: "not a symlink", stat: func(string) (os.FileMode, uint32, error) { return os.ModeDir, 0, nil }, resolve: resolveExpected},
		{name: "wrong target", stat: symlink, resolve: func(string) (string, error) { return "/attacker/tmp", nil }},
		{name: "stat failure", stat: func(string) (os.FileMode, uint32, error) { return 0, 0, os.ErrNotExist }, resolve: resolveExpected},
		{name: "resolution failure", stat: symlink, resolve: func(string) (string, error) { return "", os.ErrNotExist }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			require.False(t, trustedDarwinSystemAliasWith("/tmp", "/private/tmp", test.stat, test.resolve))
		})
	}
}

type internalFixedLocator struct{ path string }

func (l internalFixedLocator) Locate() (string, error) { return l.path, nil }

func TestApplyCommitFailureRollsBackOnlyTransactionFilesAndDirectories(t *testing.T) {
	template := filepath.Join(t.TempDir(), "IOSDebugKit")
	require.NoError(t, os.MkdirAll(filepath.Join(template, "Templates"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(template, "Package.swift"), []byte("package"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(template, "Templates", "IOSDebugBootstrap.swift"), []byte("bootstrap"), 0o644))
	root := t.TempDir()
	preexisting := filepath.Join(root, "keep.txt")
	require.NoError(t, os.WriteFile(preexisting, []byte("keep"), 0o600))
	preexistingConfig := filepath.Join(root, ".ios-debug.toml")
	require.NoError(t, os.WriteFile(preexistingConfig, []byte(projectConfig), 0o600))
	plan, err := Plan(root, internalFixedLocator{path: template})
	require.NoError(t, err)

	commits := 0
	_, err = applyWithCommitHook(plan, func(string) error {
		commits++
		if commits == 2 {
			return errors.New("injected commit failure")
		}
		return nil
	})
	require.Equal(t, contract.IOFailure, contract.CodeOf(err))
	require.Equal(t, "keep", mustReadInternal(t, preexisting))
	require.Equal(t, projectConfig, mustReadInternal(t, preexistingConfig))
	require.NoDirExists(t, filepath.Join(root, "DebugTools"))
}

func TestPlanResultCannotMutateApplySnapshot(t *testing.T) {
	template := filepath.Join(t.TempDir(), "IOSDebugKit")
	require.NoError(t, os.MkdirAll(filepath.Join(template, "Templates"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(template, "Package.swift"), []byte("package"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(template, "Templates", "IOSDebugBootstrap.swift"), []byte("bootstrap"), 0o644))
	root := t.TempDir()
	plan, err := Plan(root, internalFixedLocator{path: template})
	require.NoError(t, err)
	exposed := plan.Result(true)
	for index := range exposed.Files {
		if len(exposed.Files[index].contents) > 0 {
			exposed.Files[index].contents[0] ^= 0xff
		}
	}

	_, err = Apply(plan)
	require.NoError(t, err)
	require.Equal(t, "package", mustReadInternal(t, filepath.Join(root, "DebugTools", "IOSDebugKit", "Package.swift")))
	require.Equal(t, "bootstrap", mustReadInternal(t, filepath.Join(root, "DebugTools", "IOSDebugBootstrap.swift")))
}

func TestApplyFailsClosedWhenDestinationAppearsDuringCommit(t *testing.T) {
	template := filepath.Join(t.TempDir(), "IOSDebugKit")
	require.NoError(t, os.MkdirAll(filepath.Join(template, "Templates"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(template, "Package.swift"), []byte("package"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(template, "Templates", "IOSDebugBootstrap.swift"), []byte("bootstrap"), 0o644))
	root := t.TempDir()
	plan, err := Plan(root, internalFixedLocator{path: template})
	require.NoError(t, err)
	target := filepath.Join(root, "DebugTools", "IOSDebugBootstrap.swift")

	_, err = applyWithCommitHook(plan, func(path string) error {
		if path == target {
			require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
			require.NoError(t, os.WriteFile(path, []byte("concurrent"), 0o600))
		}
		return nil
	})
	require.Equal(t, contract.IOFailure, contract.CodeOf(err))
	require.Equal(t, "concurrent", mustReadInternal(t, target))
	require.NoFileExists(t, filepath.Join(root, ".ios-debug.toml"))
	require.NoDirExists(t, filepath.Join(root, "DebugTools", "IOSDebugKit"))
}

func mustReadInternal(t *testing.T, path string) string {
	t.Helper()
	contents, err := os.ReadFile(path)
	require.NoError(t, err)
	return string(contents)
}
