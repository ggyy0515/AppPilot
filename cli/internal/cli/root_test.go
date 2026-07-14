package cli_test

import (
	"bytes"
	"encoding/json"
	"io"
	"testing"

	"github.com/stretchr/testify/require"
	"github.com/yangy003/ios-debug-system/cli/internal/cli"
)

func TestExecuteJSONParseErrorKeepsStdoutPure(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := cli.Execute([]string{"--json", "--port", "70000", "doctor"}, &stdout, &stderr, cli.Dependencies{})

	require.Equal(t, 2, code)
	require.JSONEq(t, `{"ok":false,"error":{"code":"config_invalid","message":"Configuration is invalid.","hint":"Use a port from 1 through 65535."}}`, stdout.String())
	require.NotContains(t, stdout.String(), "Usage:")
	require.Empty(t, stderr.String())
}

func TestExecuteFindsJSONFlagAfterCommand(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := cli.Execute([]string{"doctor", "--json", "--port", "70000"}, &stdout, &stderr, cli.Dependencies{})

	require.Equal(t, 2, code)
	require.JSONEq(t, `{"ok":false,"error":{"code":"config_invalid","message":"Configuration is invalid.","hint":"Use a port from 1 through 65535."}}`, stdout.String())
	require.Empty(t, stderr.String())
}

func TestExecuteTextErrorIsConciseAndRedacted(t *testing.T) {
	var stdout, stderr bytes.Buffer
	code := cli.Execute([]string{"--port", "70000", "doctor"}, &stdout, &stderr, cli.Dependencies{})

	require.Equal(t, 2, code)
	require.Empty(t, stdout.String())
	require.Equal(t, "ios-debug: Configuration is invalid. Use a port from 1 through 65535.\n", stderr.String())
	require.NotContains(t, stderr.String(), "70000")
}

func TestRootDefinesStableShell(t *testing.T) {
	var stdout, stderr bytes.Buffer
	root := cli.NewRoot(cli.Dependencies{Version: "1.2.3", Stdout: &stdout, Stderr: &stderr})

	require.Equal(t, "ios-debug", root.Use)
	require.Equal(t, "Debug an opted-in iOS App through a stable local protocol", root.Short)
	require.Equal(t, "1.2.3", root.Version)
	require.True(t, root.SilenceErrors)
	require.True(t, root.SilenceUsage)
	for _, name := range []string{"json", "device", "port", "output-dir", "transport", "tcp-host"} {
		require.NotNilf(t, root.PersistentFlags().Lookup(name), "missing persistent flag %s", name)
	}
}

func TestExecuteJSONHelpWritesOneSuccessDocumentForEitherFlagOrder(t *testing.T) {
	for _, args := range [][]string{{"--json", "--help"}, {"--help", "--json"}, {"--json"}} {
		t.Run(args[0], func(t *testing.T) {
			stdout, stderr, code := execute(t, args, cli.Dependencies{Version: "1.2.3"})

			require.Equal(t, 0, code)
			require.Empty(t, stderr)
			document := decodeSingleDocument(t, stdout)
			require.Equal(t, true, document["ok"])
			data := document["data"].(map[string]any)
			require.Contains(t, data["help"], "Debug an opted-in iOS App")
			assertCompleteMeta(t, document)
		})
	}
}

func TestExecuteJSONRootWithPersistentFlagsWritesOneSuccessDocument(t *testing.T) {
	cases := [][]string{
		{"--json", "--device", "udid-1"},
		{"--device", "udid-1", "--json"},
		{"--json", "--port", "9876"},
		{"--port=9876", "--json"},
		{"--json", "--output-dir", "/tmp/artifacts"},
		{"--output-dir=/tmp/artifacts", "--json"},
		{"--json", "--transport", "usb"},
		{"--transport=usb", "--json"},
		{"--json", "--tcp-host", "127.0.0.1"},
		{"--tcp-host=127.0.0.1", "--json"},
	}
	for _, args := range cases {
		stdout, stderr, code := execute(t, args, cli.Dependencies{Version: "1.2.3"})

		require.Equal(t, 0, code, args)
		require.Empty(t, stderr, args)
		document := decodeSingleDocument(t, stdout)
		require.Equal(t, true, document["ok"], args)
		require.Contains(t, document["data"].(map[string]any)["help"], "Debug an opted-in iOS App", args)
		assertCompleteMeta(t, document)
	}
}

func TestExecuteJSONVersionWritesOneSuccessDocumentForEitherFlagOrder(t *testing.T) {
	for _, args := range [][]string{{"--json", "--version"}, {"--version", "--json"}} {
		stdout, stderr, code := execute(t, args, cli.Dependencies{Version: "1.2.3"})

		require.Equal(t, 0, code)
		require.Empty(t, stderr)
		document := decodeSingleDocument(t, stdout)
		require.Equal(t, true, document["ok"])
		require.Equal(t, "1.2.3", document["data"].(map[string]any)["version"])
		assertCompleteMeta(t, document)
	}
}

func TestExecuteTextHelpAndVersionRemainPlainText(t *testing.T) {
	helpOut, helpErr, helpCode := execute(t, []string{"--help"}, cli.Dependencies{Version: "1.2.3"})
	require.Equal(t, 0, helpCode)
	require.Contains(t, helpOut, "Debug an opted-in iOS App")
	require.Empty(t, helpErr)

	versionOut, versionErr, versionCode := execute(t, []string{"--version"}, cli.Dependencies{Version: "1.2.3"})
	require.Equal(t, 0, versionCode)
	require.Equal(t, "ios-debug version 1.2.3\n", versionOut)
	require.Empty(t, versionErr)
}

func execute(t *testing.T, args []string, deps cli.Dependencies) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := cli.Execute(args, &stdout, &stderr, deps)
	return stdout.String(), stderr.String(), code
}

func decodeSingleDocument(t *testing.T, output string) map[string]any {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewBufferString(output))
	var document map[string]any
	require.NoError(t, decoder.Decode(&document))
	var extra any
	require.ErrorIs(t, decoder.Decode(&extra), io.EOF)
	return document
}

func assertCompleteMeta(t *testing.T, document map[string]any) {
	t.Helper()
	meta := document["meta"].(map[string]any)
	require.Equal(t, float64(1), meta["protocol_version"])
	require.Equal(t, float64(0), meta["duration_ms"])
}
