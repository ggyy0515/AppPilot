package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"

	"github.com/ggyy0515/AppPilot/internal/contract"
	"github.com/ggyy0515/AppPilot/internal/protocol"
	"github.com/spf13/cobra"
)

func newRequestCommand(rt *Runtime) *cobra.Command {
	command := &cobra.Command{
		Use:   "request",
		Short: "Send an advanced read-only request",
		RunE: func(*cobra.Command, []string) error {
			return contract.New(contract.ConfigInvalid, nil)
		},
	}
	command.AddCommand(newRequestGet(rt), newRequestHead(rt))
	return command
}

func newRequestGet(rt *Runtime) *cobra.Command {
	return &cobra.Command{
		Use:   "get <path>",
		Short: "GET one concrete protocol route",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := protocol.ValidateRawPath(args[0]); err != nil {
				return err
			}
			_, selected, client, err := rt.Resolve(cmd.Context(), true)
			if err != nil {
				return err
			}
			var data json.RawMessage
			if _, err := client.DoJSON(cmd.Context(), http.MethodGet, args[0], nil, 4<<20, &data); err != nil {
				return err
			}
			humanData, err := formatRawJSON(data)
			if err != nil {
				return contract.New(contract.ProtocolMismatch, err)
			}
			return rt.Success(data, metaFor(selected, rt.Elapsed()), fmt.Sprintf("GET %s succeeded.\n%s", args[0], humanData))
		},
	}
}

func newRequestHead(rt *Runtime) *cobra.Command {
	return &cobra.Command{
		Use:   "head <path>",
		Short: "HEAD one concrete protocol route",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := protocol.ValidateRawPath(args[0]); err != nil {
				return err
			}
			_, selected, client, err := rt.Resolve(cmd.Context(), true)
			if err != nil {
				return err
			}
			metadata, err := client.DoHEAD(cmd.Context(), args[0])
			if err != nil {
				return err
			}
			metadata.Headers = safeResponseHeaders(metadata.Headers)
			return rt.Success(metadata, metaFor(selected, rt.Elapsed()), formatHEAD(args[0], metadata))
		},
	}
}

func formatHEAD(path string, metadata protocol.ResponseMetadata) string {
	var output strings.Builder
	fmt.Fprintf(&output, "HEAD %s: %d\n", path, metadata.StatusCode)
	names := make([]string, 0, len(metadata.Headers))
	for name := range metadata.Headers {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		fmt.Fprintf(&output, "%s: %s\n", humanCell(name), humanCell(strings.Join(metadata.Headers.Values(name), ", ")))
	}
	return output.String()
}

func formatRawJSON(raw json.RawMessage) (string, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return "", err
	}
	var extra any
	if err := decoder.Decode(&extra); err == nil {
		return "", fmt.Errorf("multiple JSON values")
	} else if err != io.EOF {
		return "", err
	}
	var lines []string
	appendHumanJSON(&lines, "", value)
	return strings.Join(lines, "\n") + "\n", nil
}

func appendHumanJSON(lines *[]string, path string, value any) {
	switch typed := value.(type) {
	case map[string]any:
		keys := make([]string, 0, len(typed))
		for key := range typed {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		if len(keys) == 0 {
			*lines = append(*lines, humanJSONPath(path)+": (empty object)")
			return
		}
		for _, key := range keys {
			next := key
			if path != "" {
				next = path + "." + key
			}
			appendHumanJSON(lines, next, typed[key])
		}
	case []any:
		if len(typed) == 0 {
			*lines = append(*lines, humanJSONPath(path)+": (empty list)")
			return
		}
		for index, item := range typed {
			appendHumanJSON(lines, fmt.Sprintf("%s[%d]", path, index), item)
		}
	case string:
		*lines = append(*lines, humanJSONPath(path)+": "+strconv.Quote(typed))
	case json.Number:
		*lines = append(*lines, humanJSONPath(path)+": "+typed.String())
	case bool:
		*lines = append(*lines, humanJSONPath(path)+": "+strconv.FormatBool(typed))
	case nil:
		*lines = append(*lines, humanJSONPath(path)+": null")
	default:
		*lines = append(*lines, humanJSONPath(path)+": "+fmt.Sprint(typed))
	}
}

func humanJSONPath(path string) string {
	if path == "" {
		return "value"
	}
	return humanCell(path)
}

func safeResponseHeaders(headers http.Header) http.Header {
	result := make(http.Header)
	for name, values := range headers {
		lowercase := strings.ToLower(name)
		if lowercase == "authorization" || lowercase == "set-cookie" {
			continue
		}
		if !strings.HasPrefix(lowercase, "content-") && !strings.HasPrefix(lowercase, strings.ToLower("X-IOS-Debug-")) {
			continue
		}
		result[name] = append([]string(nil), values...)
	}
	return result
}
