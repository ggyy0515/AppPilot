package scaffold_test

import (
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/contract"
	"github.com/yangy003/ap-ios-debug-system/cli/internal/scaffold"
)

const projectConfig = "port = 9876\noutput_dir = \".ap-ios-debug/artifacts\"\n"

type fixedLocator struct {
	Path string
	Err  error
}

func (l fixedLocator) Locate() (string, error) { return l.Path, l.Err }

func TestLocatorPrefersInstalledTemplateAndDoesNotUseWorkingDirectory(t *testing.T) {
	home := t.TempDir()
	installed := filepath.Join(home, ".local", "share", "ap-ios-debug", "ap-ios-debug-kit")
	makeTemplate(t, installed, "installed")

	repository := t.TempDir()
	makeTemplate(t, filepath.Join(repository, "swift", "ap-ios-debug-kit"), "repository")
	executable := filepath.Join(repository, "cli", "bin", "ap-ios-debug")

	other := t.TempDir()
	oldWorkingDirectory, err := os.Getwd()
	require.NoError(t, err)
	require.NoError(t, os.Chdir(other))
	t.Cleanup(func() { require.NoError(t, os.Chdir(oldWorkingDirectory)) })

	located, err := scaffold.NewLocator(executable, home).Locate()
	require.NoError(t, err)
	require.Equal(t, installed, located)
}

func TestLocatorFallsBackToExecutableAncestorAndRejectsSymlinkedRequiredFiles(t *testing.T) {
	home := t.TempDir()
	repository := t.TempDir()
	template := filepath.Join(repository, "swift", "ap-ios-debug-kit")
	makeTemplate(t, template, "repository")
	executable := filepath.Join(repository, "out", "debug", "ap-ios-debug")

	located, err := scaffold.NewLocator(executable, home).Locate()
	require.NoError(t, err)
	require.Equal(t, template, located)

	require.NoError(t, os.Remove(filepath.Join(template, "Package.swift")))
	require.NoError(t, os.Symlink(filepath.Join(template, "Templates", "APIOSDebugBootstrap.swift"), filepath.Join(template, "Package.swift")))
	_, err = scaffold.NewLocator(executable, home).Locate()
	require.Equal(t, contract.IOFailure, contract.CodeOf(err))
}

func TestLocatorRejectsEmptyAndRelativeInputsIndependentlyOfWorkingDirectory(t *testing.T) {
	workingDirectory := t.TempDir()
	oldWorkingDirectory, err := os.Getwd()
	require.NoError(t, err)
	require.NoError(t, os.Chdir(workingDirectory))
	t.Cleanup(func() { require.NoError(t, os.Chdir(oldWorkingDirectory)) })

	for _, test := range []struct {
		name       string
		executable string
		home       string
	}{
		{name: "empty executable", executable: "", home: t.TempDir()},
		{name: "relative executable", executable: filepath.Join("bin", "ap-ios-debug"), home: t.TempDir()},
		{name: "empty home", executable: filepath.Join(t.TempDir(), "ap-ios-debug"), home: ""},
		{name: "relative home", executable: filepath.Join(t.TempDir(), "ap-ios-debug"), home: "home"},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := scaffold.NewLocator(test.executable, test.home).Locate()
			require.Equal(t, contract.IOFailure, contract.CodeOf(err))
		})
	}
}

func TestPlanReportsCreateUnchangedConflictWithoutWriting(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, ".ap-ios-debug.toml"), "different\n", 0o600)

	plan, err := scaffold.Plan(root, fixedLocator{Path: fixtureTemplate(t)})
	require.NoError(t, err)
	result := plan.Result(true)

	require.True(t, result.DryRun)
	require.Equal(t, root, result.Root)
	require.Equal(t, filepath.Join(root, "DebugTools", "ap-ios-debug-kit"), result.PackagePath)
	require.Equal(t, "conflict", statusFor(t, result, filepath.Join(root, ".ap-ios-debug.toml")))
	require.Equal(t, "create", statusFor(t, result, filepath.Join(root, "DebugTools", "APIOSDebugBootstrap.swift")))
	require.NoDirExists(t, filepath.Join(root, "DebugTools", "ap-ios-debug-kit"))
	requireSortedPaths(t, result)
}

func TestApplyRefusesAllWritesWhenAnyConflictExists(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, ".ap-ios-debug.toml"), "different\n", 0o600)
	plan, err := scaffold.Plan(root, fixedLocator{Path: fixtureTemplate(t)})
	require.NoError(t, err)

	_, err = scaffold.Apply(plan)
	require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
	require.NoDirExists(t, filepath.Join(root, "DebugTools"))
}

func TestPlanTreatsMatchingPackageBytesWithDifferentModeAsUnchanged(t *testing.T) {
	template := copyFixture(t)
	root := t.TempDir()
	destination := filepath.Join(root, "DebugTools", "ap-ios-debug-kit", "Package.swift")
	writeFile(t, destination, readFile(t, filepath.Join(template, "Package.swift")), 0o600)
	require.NoError(t, os.Chmod(destination, 0o600))

	plan, err := scaffold.Plan(root, fixedLocator{Path: template})
	require.NoError(t, err)
	require.Equal(t, "unchanged", statusFor(t, plan.Result(true), destination))

	result, err := scaffold.Apply(plan)
	require.NoError(t, err)
	require.Equal(t, "unchanged", statusFor(t, result, destination))
	require.Equal(t, os.FileMode(0o600), fileMode(t, destination))
	require.Equal(t, readFile(t, filepath.Join(template, "Package.swift")), readFile(t, destination))
}

func TestPlanRejectsSymlinkedDestinationParentWithoutWritingOutsideRoot(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	require.NoError(t, os.Symlink(outside, filepath.Join(root, "DebugTools")))

	_, err := scaffold.Plan(root, fixedLocator{Path: fixtureTemplate(t)})
	require.Equal(t, contract.IOFailure, contract.CodeOf(err))
	require.Empty(t, directoryEntries(t, outside))
}

func TestPlanAndInitRejectSymlinkInAncestorAboveProjectRoot(t *testing.T) {
	container := t.TempDir()
	outside := t.TempDir()
	link := filepath.Join(container, "link")
	require.NoError(t, os.Symlink(outside, link))
	root := filepath.Join(link, "project")

	_, err := scaffold.Plan(root, fixedLocator{Path: fixtureTemplate(t)})
	require.Equal(t, contract.IOFailure, contract.CodeOf(err))
	require.NoDirExists(t, filepath.Join(outside, "project"))

	_, err = scaffold.InitLocal(root)
	require.Equal(t, contract.IOFailure, contract.CodeOf(err))
	require.NoDirExists(t, filepath.Join(outside, "project"))
}

func TestPlanAndInitAcceptDarwinSystemTmpAlias(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Darwin exposes /tmp as a root-owned platform alias")
	}
	container, err := os.MkdirTemp("/tmp", "ap-ios-debug-scaffold-test-*")
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, os.RemoveAll(container)) })

	root := filepath.Join(container, "project")
	plan, err := scaffold.Plan(root, fixedLocator{Path: fixtureTemplate(t)})
	require.NoError(t, err)
	_, err = scaffold.Apply(plan)
	require.NoError(t, err)
	require.FileExists(t, filepath.Join(root, ".ap-ios-debug.toml"))

	localRoot := filepath.Join(container, "local-project")
	_, err = scaffold.InitLocal(localRoot)
	require.NoError(t, err)
	require.FileExists(t, filepath.Join(localRoot, ".ap-ios-debug.toml"))
}

func TestApplyRejectsAncestorSymlinkIntroducedAfterPlanWithoutWritingOutside(t *testing.T) {
	container := t.TempDir()
	root := filepath.Join(container, "project")
	require.NoError(t, os.Mkdir(root, 0o755))
	plan, err := scaffold.Plan(root, fixedLocator{Path: fixtureTemplate(t)})
	require.NoError(t, err)
	require.NoError(t, os.Remove(root))

	outside := t.TempDir()
	require.NoError(t, os.Symlink(outside, root))
	_, err = scaffold.Apply(plan)
	require.Equal(t, contract.IOFailure, contract.CodeOf(err))
	require.Empty(t, directoryEntries(t, outside))
}

func TestApplyUsesPlanContentAndModeSnapshotAfterSourceChanges(t *testing.T) {
	template := copyFixture(t)
	source := filepath.Join(template, "Package.swift")
	require.NoError(t, os.Chmod(source, 0o640))
	root := t.TempDir()
	plan, err := scaffold.Plan(root, fixedLocator{Path: template})
	require.NoError(t, err)

	require.NoError(t, os.WriteFile(source, []byte("changed after plan"), 0o600))
	require.NoError(t, os.Chmod(source, 0o600))
	_, err = scaffold.Apply(plan)
	require.NoError(t, err)
	destination := filepath.Join(root, "DebugTools", "ap-ios-debug-kit", "Package.swift")
	require.Equal(t, readFile(t, filepath.Join(fixtureTemplate(t), "Package.swift")), readFile(t, destination))
	require.Equal(t, os.FileMode(0o640), fileMode(t, destination))
}

func TestApplyCopiesExactBytesModesAndBecomesEntirelyUnchanged(t *testing.T) {
	template := copyFixture(t)
	script := filepath.Join(template, "Sources", "APIOSDebugKit", "script.sh")
	writeFile(t, script, "#!/bin/sh\necho debug\n", 0o755)
	writeFile(t, filepath.Join(template, ".build", "secret"), "exclude", 0o644)
	writeFile(t, filepath.Join(template, "Sources", ".swiftpm", "state"), "exclude", 0o644)
	root := t.TempDir()

	plan, err := scaffold.Plan(root, fixedLocator{Path: template})
	require.NoError(t, err)
	oldUmask := syscall.Umask(0o077)
	t.Cleanup(func() { syscall.Umask(oldUmask) })
	result, err := scaffold.Apply(plan)
	syscall.Umask(oldUmask)
	require.NoError(t, err)
	require.False(t, result.DryRun)
	require.Equal(t, "create", statusFor(t, result, filepath.Join(root, ".ap-ios-debug.toml")))
	require.Equal(t, projectConfig, readFile(t, filepath.Join(root, ".ap-ios-debug.toml")))
	require.Equal(t, readFile(t, filepath.Join(template, "Package.swift")), readFile(t, filepath.Join(root, "DebugTools", "ap-ios-debug-kit", "Package.swift")))
	require.Equal(t, readFile(t, filepath.Join(template, "Templates", "APIOSDebugBootstrap.swift")), readFile(t, filepath.Join(root, "DebugTools", "APIOSDebugBootstrap.swift")))
	require.Equal(t, os.FileMode(0o755), fileMode(t, filepath.Join(root, "DebugTools", "ap-ios-debug-kit", "Sources", "APIOSDebugKit", "script.sh")))
	require.Equal(t, os.FileMode(0o600), fileMode(t, filepath.Join(root, ".ap-ios-debug.toml")))
	require.NoFileExists(t, filepath.Join(root, "DebugTools", "ap-ios-debug-kit", ".build", "secret"))
	require.NoFileExists(t, filepath.Join(root, "DebugTools", "ap-ios-debug-kit", "Sources", ".swiftpm", "state"))

	repeated, err := scaffold.Plan(root, fixedLocator{Path: template})
	require.NoError(t, err)
	repeatedResult, err := scaffold.Apply(repeated)
	require.NoError(t, err)
	for _, file := range repeatedResult.Files {
		require.Equal(t, "unchanged", file.Status, file.Path)
	}
}

func TestPlanRejectsSymlinksAndSpecialFilesInTemplate(t *testing.T) {
	for _, test := range []struct {
		name string
		add  func(*testing.T, string)
	}{
		{name: "symlink", add: func(t *testing.T, root string) {
			require.NoError(t, os.Symlink("Package.swift", filepath.Join(root, "link")))
		}},
		{name: "named pipe", add: func(t *testing.T, root string) {
			if runtime.GOOS == "windows" {
				t.Skip("named pipes use a different filesystem API on Windows")
			}
			require.NoError(t, syscall.Mkfifo(filepath.Join(root, "pipe"), 0o600))
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			template := copyFixture(t)
			test.add(t, template)
			_, err := scaffold.Plan(t.TempDir(), fixedLocator{Path: template})
			require.Equal(t, contract.IOFailure, contract.CodeOf(err))
		})
	}
}

func directoryEntries(t *testing.T, path string) []os.DirEntry {
	t.Helper()
	entries, err := os.ReadDir(path)
	require.NoError(t, err)
	return entries
}

func TestPlanReturnsExactXcodeInstructions(t *testing.T) {
	root := t.TempDir()
	plan, err := scaffold.Plan(root, fixedLocator{Path: fixtureTemplate(t)})
	require.NoError(t, err)

	require.Equal(t, []string{
		"In Xcode, select File > Add Package Dependencies…",
		"Click Add Local… and choose " + filepath.Join(root, "DebugTools", "ap-ios-debug-kit") + ".",
		"Add the APIOSDebugKit product only to a dedicated Debug app target; keep every Release or production target free of this package dependency.",
		"Add " + filepath.Join(root, "DebugTools", "APIOSDebugBootstrap.swift") + " only to the dedicated Debug app target, call try await APIOSDebugBootstrap.start() at Debug startup, and call await APIOSDebugBootstrap.stop() later at shutdown.",
	}, plan.Result(true).XcodeSteps)
}

func fixtureTemplate(t *testing.T) string {
	t.Helper()
	path, err := filepath.Abs(filepath.Join("testdata", "ap-ios-debug-kit"))
	require.NoError(t, err)
	return path
}

func copyFixture(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "ap-ios-debug-kit")
	makeTemplate(t, root, readFile(t, filepath.Join(fixtureTemplate(t), "Package.swift")))
	writeFile(t, filepath.Join(root, "Templates", "APIOSDebugBootstrap.swift"), readFile(t, filepath.Join(fixtureTemplate(t), "Templates", "APIOSDebugBootstrap.swift")), 0o644)
	return root
}

func makeTemplate(t *testing.T, root, packageBytes string) {
	t.Helper()
	writeFile(t, filepath.Join(root, "Package.swift"), packageBytes, 0o644)
	writeFile(t, filepath.Join(root, "Templates", "APIOSDebugBootstrap.swift"), "bootstrap", 0o644)
}

func writeFile(t *testing.T, path, contents string, mode os.FileMode) {
	t.Helper()
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0o755))
	require.NoError(t, os.WriteFile(path, []byte(contents), mode))
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	contents, err := os.ReadFile(path)
	require.NoError(t, err)
	return string(contents)
}

func fileMode(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Stat(path)
	require.NoError(t, err)
	return info.Mode().Perm()
}

func statusFor(t *testing.T, result scaffold.ScaffoldResult, path string) string {
	t.Helper()
	for _, file := range result.Files {
		if file.Path == path {
			return file.Status
		}
	}
	t.Fatalf("missing file plan for %s", path)
	return ""
}

func requireSortedPaths(t *testing.T, result scaffold.ScaffoldResult) {
	t.Helper()
	for index := 1; index < len(result.Files); index++ {
		require.Less(t, result.Files[index-1].Path, result.Files[index].Path)
	}
}
