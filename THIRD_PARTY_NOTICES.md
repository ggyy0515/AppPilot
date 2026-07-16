# Third-party notices

AppPilot's Go CLI uses the dependencies recorded in `cli/go.mod` and
`cli/go.sum`. Their source distributions contain the authoritative license
texts. The dependency set is permissively licensed as follows:

| License family | Dependencies |
| --- | --- |
| MIT | `Masterminds/semver`, `cenkalti/backoff`, `danielpaulus/go-ios`, `grandcat/zeroconf`, `pelletier/go-toml`, `stretchr/objx`, `stretchr/testify`, `go.mozilla.org/pkcs7`, `gopkg.in/yaml.v3` |
| Apache-2.0 | `inconshreveable/mousetrap`, `spf13/cobra`, portions of `gopkg.in/yaml.v3` |
| BSD | `google/uuid`, `miekg/dns`, `pkg/errors`, `pmezard/go-difflib`, `spf13/pflag`, `golang.org/x/*`, `howett.net/plist`, `software.sslmate.com/src/go-pkcs12` |
| ISC | `davecgh/go-spew` |

`gopkg.in/yaml.v3` includes work Copyright 2011-2016 Canonical Ltd. under
Apache-2.0. See `NOTICE`.

The Swift package currently declares no external package dependencies.
