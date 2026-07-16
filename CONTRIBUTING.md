# Contributing to AppPilot

Thanks for helping improve AppPilot. Bug reports, documentation fixes, tests,
and focused code changes are welcome.

## Before opening an issue

- Search existing issues first.
- Use GitHub Security Advisories instead of a public issue for vulnerabilities.
- Include the AppPilot version, macOS/Xcode/Go versions, the affected transport,
  and sanitized reproduction steps.
- Never include device identifiers, pairing data, bearer tokens, screenshots,
  recordings, signing identities, or unrelated App payloads.

## Development workflow

1. Fork the repository and create a focused branch.
2. Add or update tests before changing behavior.
3. Keep `APIOSDebugKit` limited to a dedicated Debug App target.
4. Run focused tests while iterating.
5. Run the full gate before submitting:

```bash
make clean && make verify && make clean
```

The real-device gate is opt-in and is not required for ordinary pull requests.
Do not attach physical-device artifacts to a public issue or pull request.

## Pull requests

- Keep each pull request scoped to one concern.
- Explain user-visible behavior, compatibility impact, and verification.
- Update README or protocol documentation when public behavior changes.
- Do not change frozen protocol routes, envelopes, error codes, or headers
  without an intentional protocol-version change and compatibility tests.
- Add release notes under the `Unreleased` section of `CHANGELOG.md` when the
  change affects users.

By submitting a contribution, you agree that it is licensed under the
Apache License 2.0.
