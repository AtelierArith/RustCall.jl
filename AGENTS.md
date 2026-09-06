@CLAUDE.md

# Agent instructions

The project conventions live in `CLAUDE.md` (the `@CLAUDE.md` line above includes it for Claude Code). Agents that do not expand that directive must read `CLAUDE.md` directly. The pull-request loop is repeated here because every agent working on this repository must follow it.

## Pull request loop

1. Branch off `origin/main`, never commit to `main`. Open a **draft** PR; commit in steps that each leave `Pkg.test()` green.
2. When CI is green, comment `@codex review`. Codex re-reviews on every push; do not push mid-round.
3. Track CI and Codex **per head SHA**.
4. For every finding: fix it with a regression test, reply on the thread with the fixing SHA, resolve. Do not resolve threads you did not act on.
5. When findings converge on one class that a tech-debt issue owns, post a "scope decision" comment naming that issue, stop re-requesting review, merge on green, and record the deferred items on the issue.
6. `Closes #N` only when every acceptance criterion of #N has a named test (criterion → test in the PR body); otherwise `Advances #N` with the remainder listed.
7. Squash-merge with subject `<PR title> (#PR)` once CI is green and no threads are unresolved.

## Before running tests

- `cd deps/rustcall_extract && cargo build --release` and export `RUSTCALL_EXTRACT=<path to rustcall-extract>`.
- Golden corpus: `UPDATE_GOLDEN=1 cargo test` in `deps/rustcall_core`, then review the diff.
- All `scripts/lint_*.sh src` must pass; `julia --project=docs docs/make.jl` must exit 0.

## Rules CI enforces

- No `(@ref)` links to internal bindings in `src/*.jl` docstrings.
- No `include` lines in `test/runtests.jl`; `test_*.jl` files are discovered automatically.
- No regexes over Rust source in `src/`; Rust syntax is parsed only in `deps/rustcall_core`.
- One artifact-identity function (`src/artifact_id.jl`), one load path (`src/loadpolicy.jl`), one FFI type table (`src/ffi_contract.jl`); the lints reject new ad-hoc keys, `dlopen` sites, or type maps.
- Windows: unload libraries before deleting temp trees; a mapped DLL cannot be removed.
- Finalizers never lock, `dlsym`, or log.
