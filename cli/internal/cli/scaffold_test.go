package cli_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ios-debug-system/cli/internal/cli"
)

const localProjectConfig = "port = 9876\noutput_dir = \".ios-debug/artifacts\"\n"

func TestScaffoldCommandEmitsStableJSONAndDryRunDoesNotWrite(t *testing.T) {
	root := t.TempDir()
	repository := commandRepository(t)
	stdout, stderr, code := execute(t, []string{"--json", "app", "scaffold", "--into", root, "--dry-run"}, cli.Dependencies{
		ExecutablePath: filepath.Join(repository, "cli", "ios-debug"),
		UserHome:       t.TempDir(),
	})

	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	document := decodeSingleDocument(t, stdout)
	data := document["data"].(map[string]any)
	require.Equal(t, root, data["root"])
	require.Equal(t, filepath.Join(root, "DebugTools", "IOSDebugKit"), data["package_path"])
	require.Equal(t, true, data["dry_run"])
	files := data["files"].([]any)
	require.NotEmpty(t, files)
	for _, raw := range files {
		file := raw.(map[string]any)
		require.ElementsMatch(t, []string{"path", "status"}, mapKeys(file))
		require.True(t, filepath.IsAbs(file["path"].(string)))
	}
	require.Len(t, data["xcode_steps"], 4)
	require.NoDirExists(t, filepath.Join(root, "DebugTools"))
}

func TestScaffoldCommandHumanModePrintsOrderedPathsAndXcodeSteps(t *testing.T) {
	root := t.TempDir()
	repository := commandRepository(t)
	stdout, stderr, code := execute(t, []string{"app", "scaffold", "--into", root, "--dry-run"}, cli.Dependencies{
		ExecutablePath: filepath.Join(repository, "build", "ios-debug"),
		UserHome:       t.TempDir(),
	})

	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.NotContains(t, stdout, `{"ok":`)
	require.Contains(t, stdout, "create\t"+filepath.Join(root, ".ios-debug.toml"))
	require.Contains(t, stdout, "In Xcode, select File > Add Package Dependencies…")
	require.Contains(t, stdout, filepath.Join(root, "DebugTools", "IOSDebugBootstrap.swift"))
}

func TestInitLocalCreatesOnlyExactProjectTOMLAndIsIdempotent(t *testing.T) {
	root := t.TempDir()
	deps := cli.Dependencies{WorkingDir: root}

	stdout, stderr, code := execute(t, []string{"--json", "init", "--local"}, deps)
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.Equal(t, localProjectConfig, readCLIFile(t, filepath.Join(root, ".ios-debug.toml")))
	require.Equal(t, os.FileMode(0o600), cliFileMode(t, filepath.Join(root, ".ios-debug.toml")))
	data := decodeSingleDocument(t, stdout)["data"].(map[string]any)
	require.Equal(t, "create", data["status"])
	require.Equal(t, filepath.Join(root, ".ios-debug.toml"), data["path"])
	require.Len(t, directoryEntries(t, root), 1)

	stdout, stderr, code = execute(t, []string{"--json", "init", "--local"}, deps)
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	data = decodeSingleDocument(t, stdout)["data"].(map[string]any)
	require.Equal(t, "unchanged", data["status"])
}

func TestInitLocalRefusesDifferingProjectTOMLWithoutChangingIt(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, ".ios-debug.toml")
	require.NoError(t, os.WriteFile(path, []byte("different\n"), 0o600))

	stdout, stderr, code := execute(t, []string{"--json", "init", "--local"}, cli.Dependencies{WorkingDir: root})
	require.Equal(t, 2, code)
	require.Empty(t, stderr)
	require.Equal(t, "different\n", readCLIFile(t, path))
	errorData := decodeSingleDocument(t, stdout)["error"].(map[string]any)
	require.Equal(t, "config_invalid", errorData["code"])
}

func TestInitLocalAcceptsMatchingProjectTOMLWithDifferentModeWithoutChmod(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, ".ios-debug.toml")
	require.NoError(t, os.WriteFile(path, []byte(localProjectConfig), 0o644))
	require.NoError(t, os.Chmod(path, 0o644))

	stdout, stderr, code := execute(t, []string{"--json", "init", "--local"}, cli.Dependencies{WorkingDir: root})
	require.Equal(t, 0, code)
	require.Empty(t, stderr)
	require.Equal(t, localProjectConfig, readCLIFile(t, path))
	require.Equal(t, os.FileMode(0o644), cliFileMode(t, path))
	data := decodeSingleDocument(t, stdout)["data"].(map[string]any)
	require.Equal(t, "unchanged", data["status"])
}

func TestInitLocalRejectsSymlinkedProjectRootWithoutWritingThroughIt(t *testing.T) {
	container := t.TempDir()
	outside := t.TempDir()
	root := filepath.Join(container, "project")
	require.NoError(t, os.Symlink(outside, root))

	stdout, stderr, code := execute(t, []string{"--json", "init", "--local"}, cli.Dependencies{WorkingDir: root})
	require.Equal(t, 6, code)
	require.Empty(t, stderr)
	require.NoFileExists(t, filepath.Join(outside, ".ios-debug.toml"))
	require.Equal(t, "io_failure", decodeSingleDocument(t, stdout)["error"].(map[string]any)["code"])
}

func TestInitRequiresLocalFlag(t *testing.T) {
	stdout, _, code := execute(t, []string{"--json", "init"}, cli.Dependencies{WorkingDir: t.TempDir()})
	require.Equal(t, 2, code)
	require.Equal(t, "config_invalid", decodeSingleDocument(t, stdout)["error"].(map[string]any)["code"])
}

func commandRepository(t *testing.T) string {
	t.Helper()
	repository := t.TempDir()
	template := filepath.Join(repository, "swift", "IOSDebugKit")
	require.NoError(t, os.MkdirAll(filepath.Join(template, "Templates"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(template, "Package.swift"), []byte("package"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(template, "Templates", "IOSDebugBootstrap.swift"), []byte("bootstrap"), 0o644))
	return repository
}

func mapKeys(value map[string]any) []string {
	result := make([]string, 0, len(value))
	for key := range value {
		result = append(result, key)
	}
	return result
}

func readCLIFile(t *testing.T, path string) string {
	t.Helper()
	contents, err := os.ReadFile(path)
	require.NoError(t, err)
	return string(contents)
}

func cliFileMode(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Stat(path)
	require.NoError(t, err)
	return info.Mode().Perm()
}

func directoryEntries(t *testing.T, path string) []os.DirEntry {
	t.Helper()
	entries, err := os.ReadDir(path)
	require.NoError(t, err)
	return entries
}
