---
name: release-rustcall
description: Release RustCall.jl through its registration issue, including explicit breaking-change notes for pre-1.0 minor releases and verification of General registration and TagBot. Use when asked to release or register this repository, not for unrelated version edits.
---

# Release RustCall.jl

Follow the user's requested scope and the current [AGENTS.md](../../../AGENTS.md)
and [CLAUDE.md](../../../CLAUDE.md). A release request does not necessarily need
another source change: first determine what is already on `main`.

## Establish the release state

Read `Project.toml` from the remote `main`, record its commit SHA, and confirm
that its version matches the requested release. Check the changelog and merged
changes since the previous registered version for the release notes. Inspect:

- [Registration issue #229](https://github.com/AtelierArith/RustCall.jl/issues/229),
  including the latest Registrator request and response.
- Any General registry PR linked by Registrator, its version, source commit,
  checks, and merge state.
- The corresponding Git tag and GitHub release, if already present.

If the desired version is already on `main`, register that version directly.
Do **not** create a version-bump or changelog-only PR merely to start a release.
An `Unreleased` heading does not by itself require a new PR. If source or version
changes are actually needed, follow the repository's branch, test, draft-PR,
review, and merge workflow before registration; do not commit on `main`.

If registration is already pending for the same version and intended source,
follow that PR instead of posting another trigger. If it is already registered,
continue with TagBot verification. Investigate a mismatched commit or failed
request before retrying; do not repeatedly post registration commands.

## Register with release notes

Post to **issue #229**, not to a pull request. Registrator is disabled for PR
comments in this repository. Prefer the GitHub connector; the CLI fallback is:

```sh
gh issue comment 229 --repo AtelierArith/RustCall.jl --body-file /tmp/rustcall-release-notes.md
```

Prepare the exact comment in a file or structured tool argument. Immediately
before posting, recheck remote `main`; if it moved, inspect the new commit and
confirm the intended version and notes still apply. Use this shape, replacing
the guidance with verified facts:

```markdown
@JuliaRegistrator register

Release notes:

## Breaking changes

RustCall.jl vX.Y.Z is a breaking minor release in the pre-1.0 series.

- Describe each incompatible change, who is affected, and the migration action.

## Added

- Describe the new capabilities.

## Fixed

- Describe the user-visible fixes.

See the [CHANGELOG](link-to-the-registered-source).
```

For a pre-1.0 minor release with breaking changes, explicitly name them under
`## Breaking changes`; “new features” or a changelog link alone is insufficient.
Do not infer every release's changes from a previous release's notes. For a
patch release, omit empty headings and describe the actual changes.

In particular, verify these contracts for the release being registered:

- The manifest schema and written-bindings format track the Julia package's
  `MAJOR.MINOR`. When that changes, name the old and new identifiers, explain
  that older-minor written bindings are rejected, and instruct users to
  regenerate them with `RustCall.write_bindings_to_file`. Editing a saved format
  marker is not a migration.
- Explain required extractor or Rust producer rebuilds and ABI-marker refusals
  when the release changes generated shims. Identify affected signatures;
  avoid claiming that all existing Rust libraries require rebuilding without
  evidence.
- The three published Rust crates have an **independent shared version**.
  Name their actual version and public API/ABI changes when relevant, rather
  than equating it with the Julia package's version.

## Verify the result

Read Registrator's response and follow its General PR. Verify that the version
and source commit match the intended release. Report actionable failures from
the actual check output; do not treat posting the comment as a completed release.

After General merges, confirm that TagBot creates the expected tag and GitHub
release for the registered source. This repository's TagBot responds to the
`JuliaTagBot` actor and supports manual dispatch; an ordinary user's issue
comment does not directly run its job. If TagBot fails or has not run, inspect
its workflow and logs before retrying. Do not create a competing manual tag or
move an existing release tag to hide a mismatch.

Keep the states distinct in reports: registration requested, registry PR pending,
registered, and GitHub tag/release published. Include the relevant URLs. If the
user asked only for the issue comment, report the comment and any observed
response; do not expand the task into workflow changes or unrelated publishing.

## Rust crate publication is separate

Check crates.io and the current status of `Publish Rust crates` when crate
publication matters to the requested release. A workflow file in the repository
does not prove that its workflow is enabled. Read
[PublishCrates.yml](../../../.github/workflows/PublishCrates.yml) and
[publish_rust_crates.sh](../../../scripts/publish_rust_crates.sh) when acting on
that publication path.

The dependency order is `rustcall_julia_core` → `rustcall_julia_macros_impl` →
`rustcall_julia_macros`. Follow AGENTS.md for versions, exact dependency pins,
lockfiles, dry runs, and the green-main publication gate. A dry run that cannot
check a crate because its sibling dependency is unpublished is not a pass for
that crate.

Report unpublished crates or a disabled workflow separately from Julia
registration. Respect any explicit “issue comment only” scope: do not enable a
workflow, dispatch publication, or upload crates as a side effect of that task.
