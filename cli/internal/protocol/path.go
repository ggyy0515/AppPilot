package protocol

import (
	"net/url"
	"path"
	"strings"

	"github.com/ggyy0515/AppPilot/internal/contract"
)

const invalidPathHint = "Pass one concrete /v1/... route without a query, fragment, directory, or traversal segment."

func ValidateRawPath(value string) error {
	u, err := url.ParseRequestURI(value)
	valid := err == nil && u.Scheme == "" && u.Host == "" && u.User == nil &&
		u.RawQuery == "" && u.Fragment == "" && u.RawPath == "" &&
		u.EscapedPath() == u.Path && strings.HasPrefix(u.Path, "/v1/") &&
		!strings.HasSuffix(u.Path, "/") && !strings.Contains(u.Path, "//") &&
		path.Clean(u.Path) == u.Path
	if !valid {
		return contract.NewWithHint(contract.ConfigInvalid, err, invalidPathHint)
	}
	return nil
}
