# Security Policy

## Supported versions

Security fixes are provided for the latest release on the default branch.
Pre-release snapshots and older releases may require upgrading before a fix is
available.

## Reporting a vulnerability

Do not open a public issue. Use the repository's private GitHub Security
Advisory form:

https://github.com/ggyy0515/AppPilot/security/advisories/new

Include a minimal reproduction, impact, affected versions, and any proposed
mitigation. Remove device identifiers, pairing records, bearer tokens, signing
material, screenshots, recordings, and unrelated App data.

You should receive an acknowledgement within seven days. Timing for validation,
fixes, and disclosure depends on severity and reproducibility. Please allow a
coordinated disclosure window before publishing details.

## Security boundary

AppPilot is a Debug-only development tool. The runtime listener must remain
loopback-only, paired USB is the physical-device trust boundary, and Release
builds must not contain the AppPilot runtime listener or `APIOSDebugKit`.
