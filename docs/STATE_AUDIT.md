# STATE transaction audit (#251)

This records the package-owned runtime paths inspected for the state-container
migration. It is not a claim that arbitrary extension code can call a private
helper, mutate exposed legacy data, or hold STATE around a public operation
safely. The lock-ordering contract is in the `RustCallState` docstring and
`CLAUDE.md`.

## Transaction boundaries

| Path | Work outside STATE | Work inside STATE | Regression evidence |
| --- | --- | --- | --- |
| Loading and FFI target resolution | Input validation, opening, eager and cold symbol lookup, closing | Publish prepared metadata; capture handle, ABI, cached pointers, liveness and generation together | `cold symbol resolution releases STATE and retains the captured generation (#251)`; `invalid registration inputs do not acquire a loader reference (#251)` |
| Metadata refresh | Iterate caller inputs and convert names/types into concrete rows | Clear old rows and install prepared rows atomically | `metadata iterators run outside STATE and fail before publication (#251)` |
| Retirement | Materialize requested handles; close selected owned references after publication | Select records, make images inert, remove their generic member maps | `registry argument conversion and retirement iteration release STATE (#251)`; retired-drain tests in `test_loadpolicy.jl` |
| StateView defaults and filters | Evaluate factories and predicates on captured inputs | Read/cache publication; observe mutations and publish only unchanged entries | `state cache factories run outside STATE and preserve a concurrent winner (#251)`; filter callback and delete/reinsert tests in `test_state.jl` |
| FFI layout registration | Invoke layout callbacks; acquire the separate method-definition gate; edit methods | Obtain the gate from state | `FFI layout callbacks and method definitions run outside STATE (#251)` |
| Caller modules | Read immutable precompile records; copy legacy inputs; define bindings | Select owned tables; validate collisions and publish related rows together | `legacy module adoption copies containers outside STATE (#251)`; generated-module and fresh-process precompile tests |
| Compiler and generic registration | Probe tools, extract signatures, specialize, compile and load artifacts | Capture registrations; publish complete member sets and cache winners | compiler initialization, specialization and atomic generic-group registration tests |
| Hot reload | File I/O, builds, scheduling/waiting and callbacks | Capture watch-task state; publish the replacement generation and mirrors | `inline compile, calls and cache hits overlap reloads (#251)` |
| Finalizers | Call captured destructors with captured liveness; count failures | No state transaction or registry access | `test_finalizers.jl` |

The transitive inspection includes metadata install/copy/purge, retirement and
handle-mirror helpers, module collision/publication helpers, and StateView
mutation/filter bookkeeping. These operate on prepared concrete names,
package-owned records and built-in storage. In particular, the preparation
helper must not be moved into a caller's outer transaction. The internal
`_state_read` closure is a trusted in-memory transaction, not a user callback API.

## Mechanical and runtime checks

The acceptance criteria of #251 map to the following checks. The snapshot
extension in #362 also captures destructor panic readers outside STATE; its
cold-lookup regression checks the old and replacement channels independently.

| Acceptance criterion | Evidence to verify on the PR head |
| --- | --- |
| No independent module-level mutable registry | `the mutable runtime registry lives in one Lockable state (#251)` in `test_state.jl`, plus `scripts/lint_state_container.sh` |
| Four-thread, bounds-checked concurrent compilation, calls, cache hits and reload | CI's `Bounds-checked state and mixed reload stress` step; `inline compile, calls and cache hits overlap reloads (#251)` in `test_hot_reload_transaction.jl` |
| Documented lock ordering and no FFI/user callbacks under STATE | `RustCallState` docstring, the transaction audit above, AST transaction guard in `test_state.jl`, and the named callback/cold-resolution regressions in the table |

The same CI step additionally runs `test_generic_reload.jl`: real Cargo
reloads overlap calls and panics on retained generic objects, while new
specializations and destructor counts are checked against their own images
(#291). This complements, rather than substitutes for, the mixed compilation
stress required by #251.

- `test_state.jl` inspects actual module values, including nested containers,
  rather than recognizing only constructor spellings. Runtime registries and
  generated-module tables must be StateViews; immutable lookup tables remain
  immutable. Adopted caller constants become historical snapshots, not live
  aliases to owned storage.
- Its Julia-AST transaction guard rejects explicit FFI, loader operations,
  blocking I/O, logging, method edits, metadata preparation and String
  conversions under STATE. This guard supplements, not replaces, the helper
  audit above.
- `.github/workflows/CI.yml` runs `test_state.jl` and
  `test_hot_reload_transaction.jl` with `--threads=4 --check-bounds=yes` in the
  dedicated four-thread job. The mixed reload test overlaps inline compilation,
  calls and cache hits with actual reloads.
- CI and review results are tracked per PR head. A source audit or an older
  green run does not certify a new head; the PR acceptance mapping records the
  latest validated SHA before this issue is marked closed.
