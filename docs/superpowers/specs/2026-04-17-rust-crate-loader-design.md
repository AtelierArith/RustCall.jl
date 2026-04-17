# `@rust_crate` Loader Redesign

**Date:** 2026-04-17
**Status:** proposed
**Scope:** `@rust_crate` runtime API, crate-binding runtime representation, docs contract, regression coverage

## Context

Current `@rust_crate` behavior mixes two models:

1. It generates a Julia module expression and evaluates it into the caller's namespace.
2. It also returns a proxy object that can safely invoke generated bindings.

This split design creates an unstable user contract:

- `bindings = @rust_crate ...` works because calls go through a proxy that uses `invokelatest`.
- Top-level examples such as `@rust_crate "/path/to/crate"; MyCrate.add(...)` can fail on Julia 1.12 due to world-age behavior.
- The implementation keeps runtime semantics tied to `Core.eval`, caller module injection, and dynamically generated module names.

The current model is harder to reason about than necessary. It also makes documentation ambiguous because two different usage styles are presented, but only one is robust.

## Goals

- Remove world-age-sensitive runtime behavior from the supported `@rust_crate` user path.
- Make the runtime API explicit: `@rust_crate` returns a value, and the caller chooses where to bind it.
- Keep one public runtime abstraction for dynamic crate loading.
- Preserve a separate static/precompilation path through `write_bindings_to_file`.
- Update docs so examples match the supported runtime contract.
- Add regression tests that exercise the documented user paths.

## Non-Goals

- Backward compatibility with implicit module injection behavior.
- Preserving undocumented implementation details of the current generated module path.
- Redesigning the static bindings file format used by `write_bindings_to_file`.
- Publishing or registering the package.

## Recommended Approach

Replace implicit module injection with a value-oriented loader API.

### New Runtime Contract

`@rust_crate` will:

- scan and build the target crate,
- materialize the callable binding surface,
- return a `CrateBindings` value,
- never define a global module as a side effect.

Supported usage becomes:

```julia
const MyCrate = @rust_crate "/path/to/my_crate"
MyCrate.add(Int32(1), Int32(2))
p = MyCrate.Point(3.0, 4.0)
MyCrate.distance(p)
```

Function-scope usage remains:

```julia
function load_my_crate(crate_path)
    bindings = @rust_crate crate_path name="MyCrate"
    return bindings.add(Int32(1), Int32(2))
end
```

The `name=` option remains useful for display/debug purposes and for generated metadata, but not for injecting a module into the caller.

## API Design

### Public Runtime Types

Introduce or rename the runtime proxy surface to an explicit public abstraction:

- `CrateBindings`
- `CrateBindingMember`
- `CrateBindingObject`

The current `CrateBindingsProxy` naming is implementation-oriented. The new names should communicate that these are the supported runtime handles for loaded crates.

### `@rust_crate`

`@rust_crate(path, options...)` will expand to code that:

1. resolves options,
2. loads/builds the crate,
3. constructs and returns a `CrateBindings` object.

It will not call `Core.eval` into the caller's module.

### Runtime Loading Pipeline

Split the current responsibilities more clearly:

- binding discovery: scan crate metadata and Julia-exposed Rust items
- library build/load: produce or reuse the dynamic library
- runtime binding object construction: create a `CrateBindings` value from the discovered metadata and loaded library

The implementation may still internally generate code if that remains the simplest route, but the generated code must become an internal detail of the loader rather than part of the caller-facing contract.

### Static / Precompiled Path

`write_bindings_to_file` remains the explicit path for users who want generated Julia source files and package precompilation.

This keeps the product surface clean:

- dynamic use: `@rust_crate` returns `CrateBindings`
- static/precompiled use: `write_bindings_to_file(...)` + `include(...)`

## Behavioral Changes

### Breaking Changes

- `@rust_crate "/path/to/crate"` will no longer create `MyCrate` as a new global binding.
- Docs and examples that rely on implicit module injection become invalid and must be updated.
- Any user code depending on side-effectful module creation must switch to explicit binding, such as `const MyCrate = @rust_crate ...`.

### Expected Benefits

- Removes the world-age failure mode from the supported API.
- Eliminates implicit namespace mutation from runtime loading.
- Makes user code more explicit and inspectable.
- Narrows the maintenance boundary to one runtime abstraction.
- Makes docs easier to keep correct because there is one recommended runtime pattern.

## Documentation Changes

### Installation

The docs must stop advertising `Pkg.add("RustCall")` until the package is actually installable that way.

Replace with an explicit supported path, for example:

```julia
using Pkg
Pkg.add(url="https://github.com/atelierarith/RustCall.jl")
```

For contributor-focused docs inside the repository, `Pkg.develop(path=...)` may also be shown where appropriate.

### `@rust_crate` Examples

All runtime examples should switch to explicit binding:

```julia
const MyCrate = @rust_crate "/path/to/my_crate"
MyCrate.add(Int32(1), Int32(2))
```

Function-scope examples should continue to use a local binding value.

### Optional Dependencies

Examples using `Images` or `BenchmarkTools` must declare those dependencies before `using` them.

## Testing Strategy

### Regression Tests

Add focused tests for the new public contract:

1. top-level explicit binding
   `const SampleCrate = @rust_crate path`
   verify function calls and struct/property access work
2. function-scope binding
   `bindings = @rust_crate path name="..."`
   verify calls still work
3. no implicit module injection
   after `@rust_crate path name="TmpCrate"`, confirm `isdefined(Main, :TmpCrate)` is false unless the caller explicitly assigned the return value

### Documentation Smoke Coverage

Add a small smoke test that covers the documented installation-independent examples:

- `#[julia]`
- `@rust`
- `@irust`
- `@rust_crate` explicit binding

This should exist outside `docs/make.jl`, because many raw ` ```julia ` blocks are not executed by Documenter.

## Implementation Notes

- The existing proxy calling path already demonstrates that value-oriented crate access is viable.
- The redesign should reuse the existing safe invocation path where possible rather than reintroducing direct world-age-sensitive calls.
- If internal code generation remains in place, it should be hidden behind loader functions and runtime structs rather than evaluated into the caller's namespace.
- Public docs should avoid promising that the runtime object is literally a Julia `Module`.

## Risks

- The refactor touches a feature with dynamic code generation and runtime loading, so test coverage must be expanded before cleanup.
- Existing internal helper names may still encode the old module-centric model; renaming should be done deliberately to avoid hybrid terminology.
- If code generation assumptions currently depend on module semantics, some generated wrappers may need to be adjusted to work cleanly inside the new runtime container.

## Open Decisions Resolved

- Backward compatibility: not required.
- Preferred runtime API: explicit value binding.
- Static bindings path: kept as a separate explicit workflow.
- Documentation baseline: only documented patterns that are verified in tests should remain.

## Rollout Plan

1. Add failing tests for the explicit binding contract and for absence of implicit module injection.
2. Refactor the runtime loader to return `CrateBindings` without caller-module mutation.
3. Rename runtime proxy types to the new public names if that improves clarity.
4. Update README and `docs/src` examples to the explicit binding form.
5. Update installation instructions and optional dependency notes.
6. Re-run targeted crate-binding tests, doc build, and documentation smoke tests.
