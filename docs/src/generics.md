# Generics Support in RustCall.jl

RustCall.jl now supports calling generic Rust functions from Julia. This document explains how to use this feature.

```@setup generics
using RustCall
```

## Overview

Generic functions in Rust use type parameters (e.g., `fn identity<T>(x: T) -> T`). RustCall.jl automatically:

1. **Detects** generic functions in `rust""` blocks
2. **Monomorphizes** them with specific type parameters when called
3. **Caches** the monomorphized instances for reuse

## Basic Usage

### Dependency-backed specializations

Generics declared in a `rust"""` block with `// cargo-deps:` are specialized
through Cargo, including generic bodies containing `#[cfg]` or `cfg!`.
Registration retains the dependency specifications, tracked build environment
and exact Cargo.lock contents. Later specializations replay that environment
and lockfile even if the session's environment or persisted lockfile changes.
The artifact identity also includes the dependency contents and build context.
The generated root package name is captured with the lockfile: changing a path
dependency's source creates a new specialization without invalidating that root
entry. Existing generic objects continue to use their original image's members.

If the effective Cargo configuration files change after registration, evaluate
the original block again: specialization rejects the mismatched configuration
instead of compiling already-pruned source under different settings. Generic
struct members, including allocation and destruction, share one Cargo-built
image per instantiation. Blocks without dependencies still use direct rustc.

### Automatic Detection

When you define a generic function in a `rust""` block, RustCall.jl automatically detects and registers it:

```julia

rust"""
#[no_mangle]
pub extern "C" fn identity<T>(x: T) -> T {
    x
}
"""

# The function is automatically registered as generic
# When you call it, it's automatically monomorphized
result = @rust identity(Int32(42))::Int32  # => 42
result = @rust identity(Float64(3.14))::Float64  # => 3.14
```

### Which `f` a call reaches

`@rust f(x)` resolves `f` the same way whether it is annotated or not, and
whether `f` turns out to be generic or not:

1. **The calling module's own `rust"""` blocks**, the most recently run first
   (for `@rust lib::f(x)`, that library alone). Each block is asked whether it
   exports a function `f` or registered a generic `f`, both at once, and the
   first block that defines `f` answers — calling the function or
   specializing the generic. So a later block of the module redefines `f`,
   whichever kind either definition is.
2. **Otherwise**, a generic registered process-wide under that name —
   `register_generic_function`, or another module's block — and then a
   function another loaded block exports (refused when two libraries do).

So two modules may each define a generic `f`, or one a generic `f` and the
other a plain `f`, and each module's `@rust f(x)` reaches its own.
`call_generic_function("f", ...)` names no module and reads the process-wide
registration: the one made last.

A generic `#[julia]` struct's constructor, methods, accessors and destructor
are resolved the same way, from the module that defines the struct: two
modules may each define a generic `Boxed`, and each module's `Boxed{Int32}(x)`
builds its own, from its own source.

### Manual Registration

You can also register a generic function by hand, from source text that is not
loaded through `rust"""`. The source is ordinary Rust: the bound
`T: std::ops::Add<Output = T>` is what lets `a + b` compile, and no
`#[no_mangle]` / `extern "C"` is needed, because the extractor emits the
exported wrapper for each instantiation:

```@example generics
code = """
pub fn generic_add<T: std::ops::Add<Output = T>>(a: T, b: T) -> T {
    a + b
}
"""

RustCall.register_generic_function("generic_add", code, [:T])

# Call with different types; each new type is monomorphized on first use
sum_i32 = RustCall.call_generic_function("generic_add", Int32(10), Int32(20))  # => 30
sum_f64 = RustCall.call_generic_function("generic_add", 1.5, 2.25)             # => 3.75
(sum_i32, sum_f64)
```


## How It Works

### 1. Type Parameter Inference

When you call a generic function, RustCall.jl infers type parameters from the argument types:

```julia
# For function: fn identity<T>(x: T) -> T
# Called with: identity(Int32(42))
# Type parameter T is inferred as Int32
```

### 2. Monomorphization

The generic function is specialized (monomorphized) with the inferred types:

```rust
// Original: fn identity<T>(x: T) -> T { x }
// Specialized: fn identity_i32(x: i32) -> i32 { x }
```

### 3. Compilation and Caching

The specialized function is compiled and cached. Subsequent calls with the same type parameters reuse the cached version.

## Advanced Usage

### Multiple Type Parameters

```julia
rust"""
#[no_mangle]
pub extern "C" fn first<T, U>(a: T, b: U) -> T {
    a
}
"""

# Type parameters are inferred from arguments
result = @rust first(Int32(10), Float64(3.14))::Int32  # => 10
```

### Explicit Type Parameters

`call_generic_function` infers the type parameters from its arguments.
[`RustCall.monomorphize_function`](@ref) takes them explicitly instead — as a
`Dict{Symbol, Type}` from parameter to Julia type — and builds (or fetches from
the cache) that one instantiation without calling it. Use it to compile an
instantiation ahead of the first call, or to inspect what was built:

```@example generics
code = """
pub fn scale<T: std::ops::Mul<Output = T>>(x: T, factor: T) -> T {
    x * factor
}
"""

RustCall.register_generic_function("scale", code, [:T])

# Explicitly monomorphize scale::<i64>; nothing is called yet
info = RustCall.monomorphize_function("scale", Dict{Symbol, Type}(:T => Int64))

# A call at the same types reuses that instantiation instead of compiling again
scaled = RustCall.call_generic_function("scale", Int64(7), Int64(6))  # => 42

# symbol: rustcall_scale_i64_<id>, argument types [Int64, Int64], returns Int64
(symbol = info.name, arg_types = info.arg_types, return_type = info.return_type, scaled)
```

Calling `monomorphize_function` again with the same `Dict` returns the cached
instantiation; [`RustCall.precompile_generics`](@ref) builds several
instantiations at once (see [Compiling several instantiations at
once](@ref)).

## Trait Bounds Support

RustCall.jl now supports parsing trait bounds in generic functions. This includes:

1. **Inline bounds**: `fn foo<T: Copy + Clone, U: Debug>(x: T) -> U`
2. **Where clauses**: `fn foo<T, U>(x: T) -> U where T: Copy, U: Debug`
3. **Generic trait bounds**: `fn foo<T: Add<Output = T>>(x: T) -> T`
4. **Mixed format**: Combining inline bounds and where clauses

### Using Trait Bounds

When registering a generic function, trait bounds are automatically parsed and stored:

```julia
using RustCall

# Define a function with trait bounds
code = """
pub fn identity<T: Copy + Clone>(x: T) -> T {
    x
}
"""

# Signatures and trait bounds come from the FFI manifest produced by the
# Rust-side parser (rustcall-extract); Julia never parses the source itself.
manifest = RustCall.extract_manifest(code; mode = "inline")
sig = only(RustCall.manifest_function_signatures(manifest; only_attributed = false))
println(sig.constraints)  # Dict(:T => RustCall.TypeConstraints([Copy, Clone]))
```


### Manually Specifying Constraints

You can also manually specify constraints when registering a generic function:

```julia
using RustCall

code = """
pub fn add<T>(a: T, b: T) -> T {
    a + b
}
"""

# Using RustCall.TypeConstraints (recommended)
constraints = Dict(:T => RustCall.TypeConstraints([
    RustCall.TraitBound("Copy", String[]),
    RustCall.TraitBound("Add", ["Output = T"])
]))
RustCall.register_generic_function("add", code, [:T], constraints)

# Or using the legacy string format (backward compatible)
RustCall.register_generic_function("add_legacy", code, [:T], Dict(:T => "Copy + Add<Output = T>"))
```

## Limitations

### Trait Bounds Validation

While trait bounds are now properly parsed and stored, runtime validation (checking if a Julia type satisfies Rust trait bounds) is not yet implemented. The bounds are stored for:

1. Documentation and introspection
2. Future code generation improvements
3. Error reporting when trait bounds are not satisfied

### Complex Type Inference

Type parameter inference is currently simplified:
- One type parameter maps to one argument (for single-parameter functions)
- Multiple type parameters map to multiple arguments in order

More complex inference (e.g., inferring from return type) is not yet supported.

### Generic methods of a non-generic struct

What is monomorphized on demand is a generic free function (above) and a
generic `#[julia]` struct, whose wrappers are instantiated per struct type
(`Pair{Int32}`). A generic `pub fn` of a **non-generic** struct —
`impl Acc { pub fn echo<T>(&self, x: T) -> T }`, or one taking `impl Trait` — is
neither: its struct's methods are bound through fixed `extern "C"` symbols, and
no struct type parameter binds the method's own. `rust"""` refuses such a
method with a `compile_error!` that names it (#471). Make it a generic free
function, write a non-generic method per type Julia calls that delegates to it,
or drop its `pub`; see
[Struct Mapping](struct_mapping.md#Generic-methods-of-a-non-generic-struct).
A method of a generic struct with parameters of its own
(`impl<T> Wrap<T> { pub fn pair<U>(..) }`) is refused the same way (#477):
instantiating the struct binds only `T`.

A generic struct's method wrappers declare the impl block's generics and
`where` clause and the method's own, with `Self` spelled as the block's type
(`where Self: Sized` becomes `where Wrap<T>: Sized`, #482), exactly as a
concrete struct's wrappers do; see
[Struct Mapping](struct_mapping.md#Where-predicates).

## API Reference

### Types

- `TraitBound(trait_name, type_params)` - Represents a single trait bound (e.g., `Copy`, `Add<Output = T>`)
- `TypeConstraints(bounds)` - Represents all trait bounds for a type parameter
- `GenericFunctionInfo` - Information about a generic Rust function

### Functions

#### Generic Function Management
- [`register_generic_function`](@ref RustCall.register_generic_function)`(func_name, code, type_params, constraints=Dict())` - Register a generic function
- `is_generic_function(func_name)` - Check if a function is generic
- [`call_generic_function`](@ref RustCall.call_generic_function)`(func_name, args...)` - Call a generic function (auto-monomorphizes)
- [`monomorphize_function`](@ref RustCall.monomorphize_function)`(func_name, type_params)` - Explicitly monomorphize a function
- `specialize_generic(source, fn_name, bindings, new_name)` - Instantiate a generic function through the `rustcall-extract` CLI
- `infer_type_parameters(func_name, arg_types)` - Infer type parameters from argument types
- `julia_type_to_rust_string(T)` - Rust spelling of a Julia type used as a generic argument

#### Trait Bounds
Trait bounds (`T: Copy + Clone`, `where T: Add<Output = T>`) are read by the
Rust-side parser and reported in the FFI manifest; Julia receives them as
`TypeConstraints` on `GenericFunctionInfo.constraints` and never parses them
from source text.

### Registries

- `GENERIC_FUNCTION_REGISTRY` - Maps function names to `GenericFunctionInfo` (process-wide: the last registration of a name)
- `GENERIC_FUNCTIONS_BY_LIB` - Maps `(library name, function name)` to the generic a `rust"""` block's library registered — its generic functions and its generic structs' wrappers (`GenericFunctionInfo.owner` names that library); what a call from that block's module resolves through
- `MONOMORPHIZED_FUNCTIONS` - Maps `(function_name, type_params_tuple)` to `FunctionInfo`

## Examples

### Example 1: Simple Generic Function

```@example generics
rust"""
#[no_mangle]
pub extern "C" fn identity<T>(x: T) -> T {
    x
}
"""

# Automatically monomorphized and called
result1 = @rust identity(Int32(42))::Int32  # => 42
result2 = @rust identity(Float64(3.14))::Float64  # => 3.14
println("Int32 result: $result1")
println("Float64 result: $result2")
```

### Example 2: Multiple Type Parameters

```@example generics
rust"""
#[no_mangle]
pub extern "C" fn first<T, U>(a: T, b: U) -> T {
    a
}
"""

result = @rust first(Int32(10), Float64(20.0))::Int32  # => 10
println("Result: $result")
```

### Example 3: Manual Registration and Monomorphization

```@example generics
# The registered source is an ordinary generic function; the extractor
# instantiates and exports it on demand. Argument types come from the manifest
# when a rust""" block is loaded; when registering by hand, pass them explicitly.
code = """
pub fn multiply<T: std::ops::Mul<Output = T>>(a: T, b: T) -> T {
    a * b
}
"""

RustCall.register_generic_function("multiply", code, [:T]; arg_types = ["T", "T"], return_type = "T")

# Call with automatic monomorphization
result = RustCall.call_generic_function("multiply", Int32(5), Int32(6))  # => 30
println("Result: $result")
```

## Implementation Details

### Code Specialization

Generic functions are instantiated by the `rustcall-extract specialize` command
(`deps/rustcall_extract`, built by `Pkg.build("RustCall")`). Given the
registered source, the function name and `T = i32`-style bindings it:

1. parses the source with `syn` (a real Rust parser, so `where` clauses, nested
   generics and comments are handled correctly),
2. replaces the type parameters in the signature and body at the AST level,
3. drops the bound generic parameters and their `where` predicates,
4. renames the function (e.g. `identity_i32`) and emits a
   `#[no_mangle] pub extern "C" fn rustcall_identity_i32` wrapper next to it
   (#279),
5. reports the resulting argument and return types in a manifest that Julia
   uses to build the `ccall`.

Struct definitions and impl blocks in the registered context are kept
unchanged, so generic struct wrappers such as `Point_new<T>` become
`Point_new_i32(x: i32) -> *mut Point<i32>`, exported as
`rustcall_Point_new_i32`, while `struct Point<T>` stays generic.

### Monomorphization Process

1. Check cache for existing monomorphized instance
2. If not cached, run `rustcall-extract specialize` on the registered source
   (generic structs use `specialize-many` so all wrappers for one type
   instantiation are emitted together)
3. Compile the specialized function, or the generic-struct wrapper group, with `rustc`
4. Load and cache the compiled library
5. Return `FunctionInfo` for the monomorphized function

### Caching Strategy

Monomorphized functions are cached by function name and the declared-order
type-parameter tuple. Generic struct wrappers for one tuple additionally share
one artifact identity, including the constructor and destructor, so an object
never crosses allocator boundaries when it is finalized.

Since #254 the cache is also on disk. Every instantiation is published to the
artifact cache under the artifact key it is already identified by, together with
a small record of what the extractor said about it (`<key>.spec.toml` beside the
cache metadata). A later session that asks for the same instantiation restores
both and runs **neither** the extractor nor `rustc`; only the library is opened.
The record is purely an optimisation — missing, unreadable or written by another
format version, it reads as a cache miss and the instantiation is rebuilt, and
the artifact key folds in the toolchain fingerprint, so a library built by a
different extractor or `rustcall_julia_core` can never be restored.

Reading the cache removes the compile and nothing else. An instantiation's
library is private to it, so it is opened from a private copy of the cached
file, exactly as a freshly compiled one is opened from its own build directory:
retiring an image and asking for the instantiation again still produces a *new*
image, with its own Rust statics and its own liveness flag (#291).

Nothing is mapped out of the cache directory itself. The cache is a mutable
store — a concurrent publisher of the same artifact rewrites that file, and
`RustCall.clear_cache()` removes it — so what is opened is always a copy.

### Compiling several instantiations at once

Lazy instantiation cannot know which types will be asked for next, so it builds
one library per type: `k` types cost `k` `rustc` invocations and map `k` images.
`RustCall.precompile_generics` takes the whole set at once and builds it as one
library with one invocation:

```julia
RustCall.precompile_generics("identity", Int32, Int64, Float64)
RustCall.precompile_generics("pair", (Int32, Int64), (Int64, Int32))
```

Each instantiation is a type (for a single-parameter generic), a tuple of types
in declaration order, or a `param => type` mapping. Instantiations already held
in memory or already in the cache are not rebuilt, so calling it twice — or in a
second session — compiles nothing.

All the instantiations of one batch live in one library, so they map **one**
image rather than one per type, in the session that built them and in every
later session that instantiates them lazily. Generic *struct* groups are built
one instantiation at a time: the wrappers of a single instantiation already
share one cdylib, which is what keeps allocation and destruction on one
allocator.

### Releasing instantiations

Lazy instantiation maps one image per type, and a long session that touches
many types accumulates them. `RustCall.release_generics` is the explicit way to
let them go — explicit, because the implicit answer is not decidable: an
instantiation hands out a raw function pointer, and a generic struct
instantiation hands out objects holding a destructor pointer and the image's
liveness flag, so the registry cannot know when nothing refers to an image any
more. You can.

```julia
RustCall.release_generics("identity")                 # every instantiation
RustCall.release_generics("identity", Int32, Int64)   # only these
RustCall.release_generics("identity"; close = true)   # and close the images
```

Releasing retires the images exactly as `unload_library` retires a library:
the instantiations leave the registry, so the next call at those types produces
a *new* image with its own statics and its own liveness flag — restored from the
on-disk cache, so neither the extractor nor `rustc` runs — while the old image
stays **mapped**, so a pointer or object that still holds it keeps working and
an object finalized later frees through the image that allocated it. `close =
true` also closes the retired images, flipping their liveness flags first so
that any surviving object goes inert instead of calling into unmapped code;
pass it only when you know no call into them is in flight and no object from
them is still in use, as for `unload_library(name; close = true)`.

Released in two steps is the safe way to reclaim: `release_generics(f)` now,
so no new call reaches the old images, and `release_generics(f; close = true)`
once you know nothing holds a pointer or an object from them. The closing call
also closes the images an earlier non-closing release of `f` retired and left
mapped (the typed form, those that carried one of the named types); its return
value still counts only the instantiations it retires itself.

Two consequences of how instantiations are laid out: instantiations built
together by `precompile_generics` share one library, so releasing one of them
releases the others with it (each comes back from the cache on its next call);
and a generic **struct** group is one library per instantiation with every
member wrapper in it, so naming any member's generic releases that
instantiation.

## See Also

- [Tutorial](tutorial.md) - General tutorial
- [Examples](examples.md) - More examples
- `test/test_generics.jl` - Test suite with examples
