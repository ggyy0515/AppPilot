package config_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ios-debug-system/cli/internal/config"
	"github.com/yangy003/ios-debug-system/cli/internal/contract"
)

func TestLoadUsesExactPrecedenceAndResolvesProjectOutput(t *testing.T) {
	cfg, err := config.Load(context.Background(), config.LoadOptions{
		CLI: config.CLIValues{
			Port:      ptr(uint16(9999)),
			Transport: ptr("tcp"),
			TCPHost:   ptr("localhost"),
		},
		LookupEnv: mapEnv(map[string]string{
			"IOS_DEBUG_DEVICE":     "env-udid",
			"IOS_DEBUG_PORT":       "9888",
			"IOS_DEBUG_OUTPUT_DIR": "env-artifacts",
			"IOS_DEBUG_TOKEN":      "redacted",
		}),
		WorkingDir: testProjectDir(t, readFixture(t, "project.toml")),
		UserHome:   testUserHome(t, readFixture(t, "user.toml")),
	})
	require.NoError(t, err)
	require.Equal(t, uint16(9999), cfg.Port)
	require.Equal(t, "env-udid", cfg.DeviceID)
	require.Equal(t, filepath.Join(cfg.WorkingDir, "env-artifacts"), cfg.OutputDir)
	require.Equal(t, "redacted", cfg.Token)
	require.Equal(t, "tcp", cfg.Transport)
	require.Equal(t, "localhost", cfg.TCPHost)
}

func TestLoadResolvesOutputDirectoryAgainstOwningSource(t *testing.T) {
	userHome := testUserHome(t, "output_dir = 'user-artifacts'\n")
	projectDir := t.TempDir()

	cfg, err := config.Load(context.Background(), config.LoadOptions{
		LookupEnv:  mapEnv(map[string]string{}),
		WorkingDir: projectDir,
		UserHome:   userHome,
	})
	require.NoError(t, err)
	require.Equal(t, filepath.Join(userHome, ".ios-debug", "user-artifacts"), cfg.OutputDir)

	require.NoError(t, os.WriteFile(filepath.Join(projectDir, ".ios-debug.toml"), []byte("output_dir = 'project-artifacts'\n"), 0o600))
	cfg, err = config.Load(context.Background(), config.LoadOptions{
		LookupEnv:  mapEnv(map[string]string{}),
		WorkingDir: projectDir,
		UserHome:   userHome,
	})
	require.NoError(t, err)
	require.Equal(t, filepath.Join(projectDir, "project-artifacts"), cfg.OutputDir)

	absolute := filepath.Join(t.TempDir(), "absolute-artifacts")
	cfg, err = config.Load(context.Background(), config.LoadOptions{
		CLI:        config.CLIValues{OutputDir: ptr(absolute)},
		LookupEnv:  mapEnv(map[string]string{}),
		WorkingDir: projectDir,
		UserHome:   userHome,
	})
	require.NoError(t, err)
	require.Equal(t, absolute, cfg.OutputDir)
}

func TestLoadUsesDefaultsWhenConfigFilesAreAbsent(t *testing.T) {
	workingDir := t.TempDir()
	cfg, err := config.Load(context.Background(), config.LoadOptions{
		LookupEnv:  mapEnv(map[string]string{}),
		WorkingDir: workingDir,
		UserHome:   t.TempDir(),
	})
	require.NoError(t, err)
	require.Equal(t, uint16(9876), cfg.Port)
	require.Equal(t, filepath.Join(workingDir, ".ios-debug", "artifacts"), cfg.OutputDir)
	require.Equal(t, "usb", cfg.Transport)
	require.Equal(t, "127.0.0.1", cfg.TCPHost)
	require.Equal(t, workingDir, cfg.WorkingDir)
}

func TestLoadRejectsTokenInEitherTOMLWithoutDisclosingIt(t *testing.T) {
	for _, tc := range []struct {
		name    string
		project string
		user    string
	}{
		{name: "project", project: "token = 'project-forbidden'\n"},
		{name: "user", user: "token = 'user-forbidden'\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := config.Load(context.Background(), config.LoadOptions{
				LookupEnv:  mapEnv(map[string]string{}),
				WorkingDir: testProjectDir(t, tc.project),
				UserHome:   testUserHome(t, tc.user),
			})
			require.Error(t, err)
			require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
			require.NotContains(t, err.Error(), "forbidden")
			require.NotContains(t, err.Error(), "project-forbidden")
			require.NotContains(t, err.Error(), "user-forbidden")
		})
	}
}

func TestLoadRejectsInvalidEnvironmentPort(t *testing.T) {
	for _, value := range []string{"0", "65536", "not-a-number"} {
		t.Run(value, func(t *testing.T) {
			_, err := config.Load(context.Background(), config.LoadOptions{
				LookupEnv:  mapEnv(map[string]string{"IOS_DEBUG_PORT": value}),
				WorkingDir: t.TempDir(),
				UserHome:   t.TempDir(),
			})
			require.Error(t, err)
			require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
		})
	}
}

func TestLoadRejectsUnknownTOMLKeys(t *testing.T) {
	for _, tc := range []struct {
		name    string
		project string
		user    string
	}{
		{name: "project", project: "unknown = true\n"},
		{name: "user", user: "unknown = true\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := config.Load(context.Background(), config.LoadOptions{
				LookupEnv:  mapEnv(map[string]string{}),
				WorkingDir: testProjectDir(t, tc.project),
				UserHome:   testUserHome(t, tc.user),
			})
			require.Error(t, err)
			require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
		})
	}
}

func TestLoadRejectsTCPHostWithUSB(t *testing.T) {
	_, err := config.Load(context.Background(), config.LoadOptions{
		CLI: config.CLIValues{
			Transport: ptr("usb"),
			TCPHost:   ptr("localhost"),
		},
		LookupEnv:  mapEnv(map[string]string{}),
		WorkingDir: t.TempDir(),
		UserHome:   t.TempDir(),
	})
	require.Error(t, err)
	require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
}

func TestLoadRejectsNonLoopbackIPLiteral(t *testing.T) {
	_, err := config.Load(context.Background(), config.LoadOptions{
		CLI: config.CLIValues{
			Transport: ptr("tcp"),
			TCPHost:   ptr("192.0.2.1"),
		},
		LookupEnv:  mapEnv(map[string]string{}),
		WorkingDir: t.TempDir(),
		UserHome:   t.TempDir(),
	})
	require.Error(t, err)
	require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
}

func TestLoadRejectsTCPHostResolutionFailure(t *testing.T) {
	_, err := config.Load(context.Background(), config.LoadOptions{
		CLI: config.CLIValues{
			Transport: ptr("tcp"),
			TCPHost:   ptr("bad host"),
		},
		LookupEnv:  mapEnv(map[string]string{}),
		WorkingDir: t.TempDir(),
		UserHome:   t.TempDir(),
	})
	require.Error(t, err)
	require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
}

func TestLoadRejectsEmptyExplicitCLIStrings(t *testing.T) {
	for _, values := range []config.CLIValues{
		{DeviceID: ptr("")},
		{OutputDir: ptr("")},
		{Transport: ptr("")},
		{TCPHost: ptr("")},
	} {
		_, err := config.Load(context.Background(), config.LoadOptions{
			CLI:        values,
			LookupEnv:  mapEnv(map[string]string{}),
			WorkingDir: t.TempDir(),
			UserHome:   t.TempDir(),
		})
		require.Error(t, err)
		require.Equal(t, contract.ConfigInvalid, contract.CodeOf(err))
	}
}

func ptr[T any](value T) *T { return &value }

func mapEnv(values map[string]string) func(string) (string, bool) {
	return func(key string) (string, bool) {
		value, ok := values[key]
		return value, ok
	}
}

func testProjectDir(t *testing.T, contents string) string {
	t.Helper()
	dir := t.TempDir()
	if contents != "" {
		require.NoError(t, os.WriteFile(filepath.Join(dir, ".ios-debug.toml"), []byte(contents), 0o600))
	}
	return dir
}

func testUserHome(t *testing.T, contents string) string {
	t.Helper()
	home := t.TempDir()
	if contents != "" {
		dir := filepath.Join(home, ".ios-debug")
		require.NoError(t, os.MkdirAll(dir, 0o700))
		require.NoError(t, os.WriteFile(filepath.Join(dir, "config.toml"), []byte(contents), 0o600))
	}
	return home
}

func readFixture(t *testing.T, name string) string {
	t.Helper()
	contents, err := os.ReadFile(filepath.Join("testdata", name))
	require.NoError(t, err)
	return string(contents)
}
