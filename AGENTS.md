# AGENTS.md

## Scope

These instructions apply to the entire AppPilot repository.

## Canonical names

- Product: AppPilot
- CLI: `ap-ios-debug`
- Codex skill: `ap-ios-debug-skill`
- Swift package directory and package name: `ap-ios-debug-kit`
- Swift modules and branded entry types use `APIOS*`; generic supporting public types keep role names.
- Demo filesystem names and schemes: `ap-ios-debug-demo*`
- Configuration and artifacts: `.ap-ios-debug.toml` and `.ap-ios-debug/`
- Environment variables: `AP_IOS_DEBUG_*`
- Go module: `github.com/yangy003/ap-ios-debug-system`

Do not introduce compatibility aliases or alternate spellings.

## Repository layout

- `cli/`: Go CLI, stable JSON contracts, device discovery, USB/TCP transport, artifacts, and scaffolding.
- `swift/ap-ios-debug-kit/`: Debug-only runtime, protocol core, templates, and Swift tests.
- `Examples/ap-ios-debug-demo/`: separate Debug and production-style Release targets.
- `codex/skills/ap-ios-debug-skill/`: installed operating workflow and safety policy.
- `scripts/`: validation, Simulator, Release, installation, and opt-in physical-device workflows.
- `docs/`: integration, protocol, troubleshooting, designs, and implementation plans.

## Development workflow

Use focused tests while editing, then run the complete gate before claiming completion:

```bash
make clean && make verify && make clean
```

Use `apply_patch` for hand edits. Preserve unrelated user changes and never commit generated App, media, DerivedData, `.build`, `.swiftpm`, `.xcresult`, `.ap-ios-debug/`, or local reference artifacts.

## Runtime and Release invariants

- `APIOSDebugKit` belongs only to a dedicated Debug App target. Profile and Archive use the production target.
- Release must contain no AppPilot runtime listener, `APIOSDebugKit` linkage, AppPilot service/configuration metadata, or AppPilot runtime symbols. Branded Demo target and type names such as `APIOSDebugDemo*` are allowed.
- Keep the listener loopback-only. Paired USB is the physical-device trust boundary.
- Protocol routes, JSON envelopes, error codes, and the `X-IOS-Debug-Protocol-Version`, `X-IOS-Debug-Request-ID`, and `X-IOS-Debug-SHA256` headers are frozen unless the protocol version is intentionally changed with compatibility tests and documentation.
- Raw write requests, arbitrary selectors, coordinates, and scripts stay unavailable.

## Device and artifact safety

- Run `doctor` before App operations and select one exact device; never guess among multiple devices.
- Controlled local stdout and `make device-smoke` output may display the selected `device_id` so the current command can address the device. Never copy it into chat, a shared or persistent report, a persistent log, or any non-temporary file. Never expose pairing data, bearer values, `AP_IOS_DEBUG_TOKEN`, or unrelated App payloads.
- For agent-driven or interactive activation, refresh actions immediately before activation and run `--dry-run` first. The generic README inspection template must never activate an Action. Deterministic repository smoke fixtures may directly activate their known Demo Actions.
- Agents MUST obtain explicit user approval immediately before activating an action whose current role is `destructive`; this is an agent policy, not a CLI-enforced authorization check.
- Prefer state and screenshots. Record only when motion or timing adds diagnostic value, and stop recording promptly.
- Treat PNG and MP4 files as sensitive mode-0600 evidence. The manual README flow stores them under `.ap-ios-debug/artifacts`; explicit `--out` and repository smoke paths may differ.
- Never report Simulator evidence as physical-device evidence.

The physical-device gate is opt-in:

```bash
AP_IOS_DEBUG_REAL_DEVICE_SMOKE=1 \
AP_IOS_DEBUG_DEVICE='My iPhone' \
AP_IOS_DEBUG_DEVELOPMENT_TEAM='TEAM_ID_FROM_XCODE' \
make device-smoke
```

## Testing expectations

- Go changes: run `go test ./...` and `go vet ./...` from `cli/`.
- Swift changes: run `swift test --package-path swift/ap-ios-debug-kit` and strict format lint.
- Protocol changes: preserve frozen-contract tests and add malformed/boundary coverage.
- Installation changes: run isolated install and transaction rollback fixtures; never test destructive paths against a real HOME.
- Documentation changes: run `./scripts/tests/check-docs-test.sh`, `./scripts/check-docs.sh`, and the canonical naming gate.

## Commits

Use a short English subject with Tristan's marker style and a trailing period: `+` add, `!` fix, `*` adjust/refactor, `-` remove. Inspect the staged diff and keep unrelated changes out of the commit.
