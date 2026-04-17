# ParallelTestRunner.jl Migration Design

## Goal

Migrate the package test entry point to `ParallelTestRunner.jl` so that:

- `Pkg.test()` remains the primary way to run tests locally and in CI.
- test files under `test/` can run in parallel as isolated units.
- GitHub Actions can opt into parallel execution with explicit worker counts.
- the migration minimizes churn in existing test files.

## Current State

The repository currently uses `test/runtests.jl` as a sequential entry point that:

- loads `RustCall` and `Test`
- `include`s every `test/test_*.jl` file manually
- defines additional inline `@testset`s at the end of `runtests.jl`

This structure has two problems for parallel execution:

1. File execution is centralized in one process, so independent test files cannot be scheduled in parallel.
2. Some tests only exist inline in `runtests.jl`, so they are not addressable as standalone file-level test units.

## Constraints

- Preserve `Pkg.test()` as the default entry point.
- Keep the migration compatible with the existing Julia package test layout.
- Avoid broad rewrites of stable test files.
- Keep CI simple by continuing to use `julia-actions/julia-runtest@v1`.
- Be conservative about worker counts because many tests compile Rust code and may consume significant CPU, memory, and filesystem resources.

## Chosen Approach

Use `ParallelTestRunner.jl` directly from `test/runtests.jl`, with file-level auto-discovery via `find_tests(@__DIR__)`.

This means:

- `Project.toml` test dependencies will add `ParallelTestRunner`.
- `test/runtests.jl` will switch from a long list of `include(...)` calls to:
  - `using ParallelTestRunner`
  - `testsuite = find_tests(@__DIR__)`
  - `runtests(RustCall, ARGS; testsuite, init_code=...)`
- Inline tests currently defined only in `test/runtests.jl` will move into a dedicated test file so they can participate in file-level scheduling.

This is the best fit because it preserves the standard package test entry point while adopting the runner in the way it is commonly used by Julia packages.

## Rejected Alternatives

### Manual `Dict`-based test suite registration

This would define the test suite explicitly in `runtests.jl` instead of using `find_tests`.

Why rejected:

- duplicates the filesystem structure in code
- adds maintenance overhead whenever a new test file is added
- provides little benefit for this repository because the test files already follow a clear `test_*.jl` naming pattern

### Partial migration while keeping most sequential includes

This would preserve the current `include(...)` chain and only parallelize a subset of tests.

Why rejected:

- leaves the suite in a mixed execution model
- weakens the benefit of the migration
- makes CI and local behavior harder to reason about

## Test Layout Changes

### `test/runtests.jl`

`test/runtests.jl` becomes a thin runner that:

- imports `RustCall`
- imports `ParallelTestRunner`
- discovers tests automatically
- optionally filters or adjusts the suite if needed
- provides shared `init_code` for each isolated test execution environment

The file should no longer contain real test bodies.

### New standalone file for inline base tests

The inline `@testset "RustCall.jl"` currently living in `test/runtests.jl` will move to a new test file, tentatively `test/test_core_api.jl`.

This file will contain:

- type mapping tests
- `RustResult` tests
- `RustOption` tests
- error construction and formatting tests
- string conversion tests
- any other base API checks currently embedded in `runtests.jl`

This keeps the runner declarative and allows the core API tests to run like every other file.

## Execution Model

Each test file will run as an isolated unit under `ParallelTestRunner.jl`.

This isolation is useful for the repository because several tests touch global state such as:

- library registries
- cache state
- hot reload registries
- compiler configuration and temporary build products

The migration relies on file-level process isolation instead of trying to make the current sequential `include(...)` chain safe for parallelism in one process.

## Shared Initialization

`runtests(RustCall, ARGS; testsuite, init_code=...)` will provide shared setup code for each worker.

The initialization should be minimal and stable. It will include:

- `using Test`
- `using RustCall`

If later needed, this hook can also set deterministic random seeds or include shared test helpers. The initial migration should avoid unnecessary setup logic.

## Test Selection and Runner Arguments

The migrated runner should preserve `ParallelTestRunner.jl` argument handling through `ARGS`, so the following use cases work without additional wrappers:

- `Pkg.test()`
- `Pkg.test(; test_args=\`--jobs=2\`)`
- `Pkg.test(; test_args=\`--list\`)`
- `Pkg.test(; test_args=\`test_cache test_generics\`)` if file selection is needed

The package should not hardcode a local default job count in `runtests.jl`. The initial behavior should rely on the runner default unless explicit arguments are passed. CI will pass explicit worker counts.

## CI Integration

The existing GitHub Actions workflow should continue using `julia-actions/julia-runtest@v1`.

The Julia test job will change by passing `test_args` to the action so that `Pkg.test()` still remains the underlying entry point while enabling the parallel runner.

Recommended initial CI worker counts:

- `ubuntu-latest`: `--jobs=4`
- `windows-latest`: `--jobs=2`
- `macos-latest` on `aarch64`: `--jobs=2`

Rationale:

- Linux generally has the most headroom in GitHub-hosted runners.
- Windows and macOS runners are often more sensitive to process startup cost and memory pressure.
- this repository compiles Rust code during tests, so aggressive worker counts may hurt stability more than they help total wall-clock time

These values are intentionally conservative and can be raised later based on observed CI behavior.

## Safety Measures

### File-level isolation first

Prefer isolated file execution over intra-file threaded execution. This lowers the risk of collisions in global registries and temporary state.

### Keep helper files out of autodiscovery

If future utility files under `test/` are not real tests, they must either:

- avoid the `test_*.jl` naming pattern, or
- be explicitly removed from `testsuite`

This avoids accidental execution of helper code as tests.

### Avoid introducing custom scheduler logic

The migration should not add package-specific worker scheduling or platform heuristics inside `runtests.jl` beyond straightforward test discovery and optional filtering. CI policy should live in the workflow file.

## Verification Plan

After implementation, verify the migration in this order:

1. `Pkg.test()` succeeds locally with the new runner entry point.
2. `Pkg.test(; test_args=\`--jobs=2\`)` succeeds locally.
3. `Pkg.test(; test_args=\`--list\`)` shows the discovered test suite.
4. The GitHub Actions workflow passes `test_args` and runs the suite in parallel on all configured platforms.

If a specific file proves unsafe under parallel execution, handle it explicitly by removing it from the discovered suite and running it separately in a controlled path. That is a fallback, not the primary design.

## Implementation Scope

The implementation for this migration includes:

- adding the test dependency
- rewriting `test/runtests.jl`
- moving inline runner tests into a standalone file
- updating GitHub Actions to pass parallel test arguments
- updating any test documentation that still describes the suite as purely sequential

The implementation does not include:

- refactoring unrelated test logic
- rewriting stable test files just to change style
- introducing per-test performance tuning beyond the initial CI worker count selection
