# AppPilot 0.1.0 Source Release Design

[Back to README](../README.md)

## Goal

Publish AppPilot 0.1.0 as a reproducible source release from
`github.com/ggyy0515/AppPilot`, with the complete Go CLI, Swift Debug Kit,
Codex skill, Demo, documentation, and installation workflow kept together.

## Distribution policy

AppPilot 0.1.0 is source-only. The GitHub Release will not attach unsigned
prebuilt CLI binaries. Users install from the tagged source because the CLI
alone is not the complete AppPilot integration and unsigned macOS downloads
would add avoidable Gatekeeper friction.

The supported installation path is:

1. Clone or download the `v0.1.0` source.
2. Run the complete verification gate.
3. Run `make install-local`.

A future release may add prebuilt artifacts only after the project defines a
complete packaging, Developer ID signing, notarization, and installation
story for all required AppPilot components.

## Release automation

The release workflow has two entry points:

- A manual dry run verifies the complete repository without creating a tag or
  GitHub Release.
- A semantic version tag such as `v0.1.0` verifies the exact tagged commit and
  creates a GitHub Release using generated release notes. GitHub supplies the
  standard source archives.

The workflow must use least-privilege permissions. Verification requires only
read access. Release publication grants `contents: write` only to the publish
job.

## Publication sequence

1. Create `ggyy0515/AppPilot` as a private repository and install the GitHub
   App for that repository.
2. Push the rewritten `main` history and confirm the GitHub CI gate passes.
3. Configure repository metadata, security features, and rulesets for `main`
   and version tags.
4. Run the manual release dry run.
5. Change the repository visibility to public.
6. Clone the public repository into a clean temporary directory and verify the
   documented source installation flow.
7. Move the final entries from `Unreleased` to a dated `0.1.0` section in the
   changelog.
8. Run the complete gate on the final commit, push it, and wait for GitHub CI.
9. Create and push the protected annotated `v0.1.0` tag.
10. Confirm the GitHub Release exists, identifies the expected commit, and its
    source archives contain the required licensing and documentation files.

## Repository policy

The public repository uses `main` as its default branch and requires the CI
verification check before merging. Force pushes and deletion are blocked for
`main`. Version tags matching `v*` cannot be updated or deleted.

Private vulnerability reporting, Dependabot alerts and security updates,
secret scanning, and push protection are enabled where available. Repository
metadata includes an AppPilot description, relevant iOS/Swift/Go debugging
topics, and Apache-2.0 license detection.

## Documentation changes

The README recommends tagged source installation and explains why 0.1.0 does
not ship prebuilt binaries. Release documentation covers the manual dry run,
the clean-clone verification, the final tag, and post-release checks. The
changelog uses the actual publication date rather than a planned placeholder.

## Failure handling

A failed dry run or CI check blocks publication. A failed tag-triggered
workflow does not justify moving the tag: fix the problem on `main`, publish a
new patch version, and preserve the immutable released tag. If the public
clean-clone installation differs from the local result, stop and correct the
documentation or installation workflow before tagging.

## Verification

Release preparation is complete only when:

- `make clean && make verify && make clean` passes on the final source tree.
- GitHub CI and the manual release dry run pass.
- A clean clone of the public repository passes verification and installation.
- The repository history contains no internal planning files or legacy author
  identities.
- The `v0.1.0` Release points to the expected commit and exposes only the
  standard source archives.
