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
- Golden corpus: run the plain `cargo test` in `deps/rustcall_core` first; a golden failure means the extractor output changed. Only if that change is intended, regenerate with `UPDATE_GOLDEN=1 cargo test` (it overwrites without comparing) and review `git diff tests/corpus`.
- All `scripts/lint_*.sh src` must pass; `julia --project=docs docs/make.jl` must exit 0.

## Rules CI enforces

- No `(@ref)` links to internal bindings in `src/*.jl` docstrings.
- No `include` lines in `test/runtests.jl`; `test_*.jl` files are discovered automatically.
- No regexes over Rust source in `src/`; Rust syntax is parsed only in `deps/rustcall_core`.
- One artifact-identity function (`src/artifact_id.jl`, enforced by `scripts/lint_artifact_identity.sh`) and one FFI type table (`src/ffi_contract.jl`, legacy tables deleted in #286). One load path through `src/loadpolicy.jl` is enforced by `scripts/lint_load_path.sh` from #277 Phase B (PR #289) onward; before that, `src/loadpolicy.jl` is the policy model only and `test/test_loadpolicy.jl` pins the open-coded `dlopen` sites.
- Windows: unload libraries before deleting temp trees; a mapped DLL cannot be removed.
- Finalizers must never lock, `dlsym`, or log — enforced by `test/test_finalizers.jl` from PR #289 onward; the older finalizers in `src/types.jl` and `src/crate_bindings.jl` are migrated there.
