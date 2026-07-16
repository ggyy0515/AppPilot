# Releasing AppPilot

[Back to README](../README.md)

AppPilot uses Semantic Versioning. The first public release is `v0.1.0`.

## Prepare

1. Move relevant entries from `Unreleased` into a dated version section in
   `CHANGELOG.md`.
2. Confirm dependency licenses and update `THIRD_PARTY_NOTICES.md`.
3. Run the complete local gate:

```bash
make clean && make verify && make clean
```

4. Confirm `git status --short` is empty.
5. Confirm GitHub Actions passes on `main`.

## Publish

Create and push an annotated tag from the verified commit:

```bash
git tag -a v0.1.0 -m 'AppPilot v0.1.0.'
git push origin v0.1.0
```

The release workflow verifies the tag, reruns the complete gate, builds
`ap-ios-debug` for macOS arm64 and amd64, includes the license and notices,
generates SHA-256 checksums, and creates the GitHub Release.

## Repository settings

Before the first release, enable private vulnerability reporting, Dependabot
alerts and security updates, secret scanning, and branch protection requiring
the `CI / verify` check. Disable force pushes and branch deletion for `main`.
