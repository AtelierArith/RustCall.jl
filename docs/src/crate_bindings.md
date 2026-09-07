# External Crate Bindings (Phase 6)

RustCall.jl provides a Maturin-like feature for generating Julia bindings from external Rust crates. This allows you to develop Rust libraries with the `#[julia]` attribute and automatically generate Julia bindings.

## Overview

The feature consists of two components:

1. **`juliacall_macros`** - A Rust proc-macro crate that provides the `#[julia]` attribute
2. **`@rust_crate`** - A Julia macro that scans external crates and generates bindings

## Quick Start

### Rust Side

Create a Rust crate with `juliacall_macros`:

```toml
# Cargo.toml
[package]
name = "my_library"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
juliacall_macros = { path = "/path/to/RustCall.jl/deps/juliacall_macros" }
# Or from crates.io (when published):
# juliacall_macros = "0.1"
```

```rust
// src/lib.rs
use juliacall_macros::julia;

#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[julia]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[julia]
impl Point {
    #[julia]
    pub fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    #[julia]
    pub fn distance(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}
```

### Julia Side

```julia
using RustCall

const MyLibrary = @rust_crate "/path/to/my_library"

MyLibrary.add(Int32(1), Int32(2))  # => 3
p = MyLibrary.Point(3.0, 4.0)
MyLibrary.distance(p)  # => 5.0
```

When loading a crate inside a function or other local scope, capture the return
value from `@rust_crate` and use that binding directly:

```julia
function load_my_library(crate_path)
    bindings = @rust_crate crate_path name="MyLibrary"
    p = bindings.Point(3.0, 4.0)
    return bindings.add(Int32(1), Int32(2)), bindings.distance(p), p.x
end
```

## The `#[julia]` Attribute

The `#[julia]` attribute simplifies FFI function definitions.

### For Functions

```rust
// Before: verbose FFI declaration
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}

// After: simple #[julia] attribute
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
```

The `#[julia]` attribute automatically:
- Adds `#[no_mangle]`
- Makes the function `pub extern "C"`

### For Structs

```rust
#[julia]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
```

This generates:
- `#[repr(C)]` for C-compatible layout
- `Point_free(ptr)` - Free function
- `Point_get_x(ptr)` / `Point_set_x(ptr, value)` - Field accessors
- `Point_get_y(ptr)` / `Point_set_y(ptr, value)` - Field accessors

On the Julia side, you can access struct fields naturally:

```julia
p = MyModule.Point(3.0, 4.0)
p.x      # => 3.0 (uses Point_get_x)
p.y      # => 4.0 (uses Point_get_y)
p.x = 5.0  # (uses Point_set_x)
```

### For Impl Blocks

```rust
#[julia]
impl Counter {
    #[julia]
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    #[julia]
    pub fn get(&self) -> i32 {
        self.value
    }
}
```

`#[julia]` is additive (#279): the `impl` block above is left exactly as
written — `Counter::new` and `Counter::get` keep their Rust signatures for
other callers, `#[test]`s and other proc-macros — and the FFI wrappers are
emitted next to it under `rustcall_`-prefixed symbols:

- `rustcall_Counter_new(initial)` - Returns `*mut Counter`
- `rustcall_Counter_get(ptr)` - Takes `*const Counter`, returns `i32`

The generated Julia bindings keep the Rust names (`Counter(1)`, `get(c)`);
they resolve the exported symbol through the manifest, so nothing in the Julia
API changes.

### Static methods

A method without `self` (other than a constructor) is called with the type as
its first argument, the Julia spelling of `Labeler::shout(s)`:

```julia
shout(Labeler, "hi")     # Labeler::shout
parse_scale(Divider, "7") # Divider::parse_scale
```

The bare `shout("hi")` form is generated as well, **unless** the crate also
has a free `#[julia] fn shout` or another struct with a static `shout`: two
bare definitions would overwrite each other — silently under `@rust_crate`,
and as a hard error when a module written by `write_bindings_to_file` is
precompiled — so in that case only the typed form exists and the free function
keeps the bare name (#323).

### Modules

Every exported symbol hangs off the item's **FFI name**: the item's own name at
the crate root, and its module path folded in otherwise
(`rustcall_core::codegen::symbol_stem`, #300). A proc-macro cannot see the
module an item sits in, so the module carries the marker too:

```rust
#[julia]
pub mod a {
    use juliacall_macros::julia;

    #[julia]
    pub fn run() -> i32 { 1 }          // exported as `rustcall_a__run`

    #[julia]
    pub struct C { pub v: i32 }        // `a__C_free`, `a__C_get_v`, `a__C_set_v`

    #[julia]
    impl C {
        #[julia]
        pub fn new(v: i32) -> Self { Self { v } }   // `rustcall_a__C_new`
    }
}

#[julia]
pub mod b {
    use juliacall_macros::julia;

    #[julia]
    pub fn run() -> i32 { 2 }          // exported as `rustcall_b__run`
}

#[julia]
pub fn run() -> i32 { 0 }              // crate root: `rustcall_run`, as before
```

`#[julia]` on an inline `mod` expands the `#[julia]` items inside it with the
module path; nested marked modules accumulate (`a::deep::run` →
`rustcall_a__deep__run`). Segments are joined with `__` and every `_` inside a
segment is spelled `_0`, so `a_b::c` (`a_0b__c`) and `a::b_c` (`a__b_0c`) can
never meet; a crate-root item keeps its bare name.

On the Julia side the generated module mirrors the Rust module tree — one
submodule per Rust module, root items where they always were:

```julia
bindings = @rust_crate "/path/to/two_modules"
bindings.run()              # 0
bindings.a.run()            # 1
bindings.b.run()            # 2
c = bindings.a.C(Int32(4))  # a distinct type from bindings.b.C
bindings.a.get(c)
```

A module written by `write_bindings_to_file` has the same shape
(`module a ... end` inside the generated module), and the static-method
rule above is decided per module.

Two things to know:

- A `#[julia]` item inside an inline module that is **not** marked `#[julia]`
  is refused by the scan, with the fix in the message: the proc-macro would
  have exported it under the crate-root symbol, which the manifest cannot
  describe honestly.
- File modules (`mod a;`) cannot carry an attribute macro (rustc's E0658) and
  are transparent: their items keep crate-root symbols, exactly as if they
  were written in `lib.rs`. Two file modules that both define `#[julia] pub fn
  run` therefore still want one `rustcall_run`; the scan reports the duplicate
  with both locations instead of describing a library that cannot be built.
  Wrap the items in a `#[julia] pub mod` block inside the file, or rename one.

## Property Access Syntax

Generated struct wrappers support Julia's property access syntax for natural field access:

```julia
# Instead of calling accessor functions directly:
get_x(p)
set_x(p, 5.0)

# You can use dot notation:
p.x        # Get field value
p.x = 5.0  # Set field value
```

This works for all FFI-compatible field types (`i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`, `f64`, `bool`, `usize`, `isize`).

You can also use `propertynames()` to list available fields:

```julia
p = MyModule.Point(1.0, 2.0)
propertynames(p)  # => (:x, :y)
```

## API Reference

### `scan_crate(path)`

Scan a Rust crate and extract `#[julia]` marked items.

```julia
info = RustCall.scan_crate("/path/to/crate")

println("Crate: ", info.name)
println("Functions: ", length(info.julia_functions))
println("Structs: ", length(info.julia_structs))
```


### `generate_bindings(path; kwargs...)`

Generate Julia bindings for an external crate.

```julia
bindings = RustCall.generate_bindings("/path/to/crate",
    output_module_name = "MyBindings",
    build_release = true,
    cache_enabled = true
)

eval(bindings)

# Now MyBindings module is available
MyBindings.add(1, 2)
```

### `@rust_crate`

Macro form for easy one-line usage.

```julia
# Basic usage
const MyCrate = @rust_crate "/path/to/crate"

# With options
const MyBindings = @rust_crate "/path/to/crate" name="CustomName" release=true cache=true
```

## Type Definitions

### `CrateInfo`

Information about a scanned Rust crate.

| Field | Type | Description |
|-------|------|-------------|
| `name` | `String` | Crate name |
| `path` | `String` | Absolute path |
| `version` | `String` | Crate version |
| `dependencies` | `Vector{DependencySpec}` | Dependencies |
| `julia_functions` | `Vector{RustFunctionSignature}` | `#[julia]` functions |
| `julia_structs` | `Vector{RustStructInfo}` | `#[julia]` structs |
| `source_files` | `Vector{String}` | .rs file paths |

### `CrateBindingOptions`

Options for binding generation.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `output_module_name` | `Union{String, Nothing}` | `nothing` | Override module name |
| `output_path` | `Union{String, Nothing}` | `nothing` | Write generated code to file |
| `use_wrapper_crate` | `Bool` | `true` | Create wrapper crate |
| `build_release` | `Bool` | `true` | Build in release mode |
| `cache_enabled` | `Bool` | `true` | Enable library caching |

## Build Process

When you call `@rust_crate`, RustCall.jl:

1. **Scans the crate** - Parses all `.rs` files for `#[julia]` attributes
2. **Checks cache** - If a cached library exists with matching hash, uses it
3. **Builds the crate** - If the crate already has `cdylib` crate-type, builds directly; otherwise creates a wrapper crate
4. **Generates Julia module** - Creates wrapper functions and struct definitions
5. **Loads the library** - Loads the compiled `.so`/`.dylib`/`.dll`

## Caching

Compiled libraries are cached based on source code hash:

```julia
# Clear the cache
RustCall.clear_cargo_cache()

# Check cache size
RustCall.get_cargo_cache_size()
```

## Supported Types

The following Rust types are supported in `#[julia]` functions:

| Rust Type | Julia Type |
|-----------|------------|
| `i8`, `i16`, `i32`, `i64` | `Int8`, `Int16`, `Int32`, `Int64` |
| `u8`, `u16`, `u32`, `u64` | `UInt8`, `UInt16`, `UInt32`, `UInt64` |
| `f32`, `f64` | `Float32`, `Float64` |
| `bool` | `Bool` |
| `usize`, `isize` | `UInt`, `Int` |
| `()` | `Cvoid` |
| `*const T`, `*mut T` | `Ptr{T}` |

## Example: Complete Workflow

### 1. Create Rust Crate

```bash
cargo new --lib my_math
cd my_math
```

### 2. Configure Cargo.toml

```toml
[package]
name = "my_math"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
juliacall_macros = { path = "/path/to/RustCall.jl/deps/juliacall_macros" }
```

### 3. Write Rust Code

```rust
// src/lib.rs
use juliacall_macros::julia;

#[julia]
fn factorial(n: u64) -> u64 {
    (1..=n).product()
}

#[julia]
fn fibonacci(n: u32) -> u64 {
    match n {
        0 => 0,
        1 => 1,
        _ => {
            let mut a = 0u64;
            let mut b = 1u64;
            for _ in 2..=n {
                let c = a + b;
                a = b;
                b = c;
            }
            b
        }
    }
}
```

### 4. Use in Julia

```julia
using RustCall

const MyMath = @rust_crate "/path/to/my_math"

MyMath.factorial(UInt64(10))  # => 3628800
MyMath.fibonacci(UInt32(20))  # => 6765
```

## Precompilation Support

For package development, you can generate bindings to a file that will be precompiled with your package, improving startup time.

### Generating Bindings to a File

```julia
using RustCall

# Generate bindings and write to a file
RustCall.write_bindings_to_file(
    "deps/my_rust_crate",              # Path to Rust crate
    "src/generated/MyRustBindings.jl", # Output file
    output_module_name = "MyRust",
    relative_lib_path = "../deps/lib"  # Path relative to the output file
)
```

### Package Development Workflow

1. **Set up your package structure**:
   ```
   MyPackage/
   ├── Project.toml
   ├── src/
   │   ├── MyPackage.jl
   │   └── generated/
   │       └── MyRustBindings.jl  # Generated bindings
   ├── deps/
   │   ├── my_rust_crate/         # Your Rust crate
   │   └── lib/                   # Compiled library
   └── test/
   ```

2. **Generate bindings during development**:
   ```julia
   using RustCall
   RustCall.write_bindings_to_file(
       "deps/my_rust_crate",
       "src/generated/MyRustBindings.jl",
       output_module_name = "MyRust",
       relative_lib_path = "../deps/lib"
   )
   ```

3. **Include in your package**:
   ```julia
   # In src/MyPackage.jl
   module MyPackage

   include("generated/MyRustBindings.jl")
   using .MyRust

   # Re-export functions if desired
   export add, multiply

   end
   ```

4. **The generated file uses `@__DIR__`** for library paths, ensuring it works when the package is installed elsewhere.

### API Reference

#### `write_bindings_to_file`

```julia
RustCall.write_bindings_to_file(
    crate_path::String,
    output_path::String;
    output_module_name = nothing,
    build_release = true,
    relative_lib_path = nothing,
    strict = RustCall.FFI_STRICT[]
) -> String
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `crate_path` | `String` | Path to the Rust crate |
| `output_path` | `String` | Path for the generated Julia file |
| `output_module_name` | `String` | Name for the generated module |
| `build_release` | `Bool` | Build in release mode |
| `relative_lib_path` | `String` | Path for library relative to output file |
| `strict` | `Symbol` | What to do when the [FFI type contract](type_contract.md) cannot describe a return type: `:error` (default), `:warn`, `:none` |

#### Unsupported types in a crate

Every return type in the generated module is resolved through the FFI contract.
A type the contract does not cover — a `Vec<T>` returned by value, say — used to
be emitted as `Any`, which is not a well-defined `ccall` slot; it now raises,
naming the signature:

```
the FFI contract cannot describe the return type of `mycrate::histogram(u32) -> Vec<f64>`
```

Change the Rust signature to something that can cross the boundary (return the
aggregate behind a `*mut`, or expose accessors), or, to keep the rest of the
crate building while you deal with it:

```julia
RustCall.write_bindings_to_file(crate_path, output_path; strict = :warn)
```

`:warn` restores the pre-#276 behaviour — one warning per signature and `Any` in
the slot — for one minor release. The generated text also changed in two ways
worth knowing about if you diff it against an older run: `usize` is spelled
`Csize_t`, `*mut i32` is `Ptr{Int32}` rather than `Ptr{Cvoid}`, and a `String`
field is read as an owned buffer instead of `Any`.

#### `emit_crate_module_code`

```julia
RustCall.emit_crate_module_code(
    info::RustCall.CrateInfo,
    lib_path::String;
    module_name = nothing,
    use_relative_path = false
) -> String
```

Returns the generated Julia module code as a string.

## Troubleshooting

### Crate not building

Ensure your crate has:
- `crate-type = ["cdylib"]` in `[lib]` section
- `juliacall_macros` as a dependency
- Valid Rust code that compiles

### Functions not found

Check that:
- Functions have the `#[julia]` attribute
- Function signatures use FFI-compatible types
- The crate builds without errors

### Type errors

Ensure you're using the correct Julia types that match the Rust function signatures.

### Precompilation issues

If you encounter precompilation issues:
- Ensure the library path is correct (use `relative_lib_path` for portable packages)
- Check that the library was copied to the correct location
- Verify the generated code compiles without errors

## Object lifetime

A struct handed to Julia by a `@rust_crate` binding is owned by Julia: its
finalizer calls the Rust destructor, so the Rust allocation is released when
the wrapper is collected. This is now also true of inline `rust"""` structs,
which used to leak.

The finalizer captures what it needs at construction — the destructor pointer
and a flag saying whether the library is still loaded — so it takes no lock and
resolves no symbol when it runs. Two consequences worth knowing:

* A method call or field access on an object whose finalizer has already run
  raises, rather than dereferencing a null pointer inside Rust.
* Unloading a library retires the objects it produced: their finalizers become
  no-ops instead of calling into an image that is no longer mapped. That leaks
  those objects deliberately — a leak is preferable to a jump into freed text.

If you need a Rust object to outlive its Julia wrapper, keep a reference to the
wrapper, or hold it inside `GC.@preserve` for the region where the raw pointer
is used. An allocation made by one library must be released by that same
library; see [Panics, Visibility and Lifetime](panics.md) for the full contract.

## Regenerating bindings after an upgrade

Files written by `write_bindings_to_file` carry a format marker
(`# Bindings format: 7`). Regenerate after upgrading RustCall.

Format `7` (#300) names every symbol module-qualified (`a__C_free`,
`rustcall_a__run`) and puts items inside Rust modules into Julia submodules.
A file emitted before it names symbols that a library built with the current
proc-macro no longer exports for any item inside a module.

Since format `6` (#309) the module's `__init__` opens a **private generation
copy** of the library rather than the file `_LIB_PATH` names, exactly as
`@rust_crate` does: that file is Cargo's output (or the copy
`write_bindings_to_file` made of it), and an image mapped in place cannot be
overwritten on Windows — the next `cargo build` of the crate, and the next
regeneration of the file, would fail with "Access is denied".

Version `3` is the first that does **not** keep working when it is older than
the RustCall loading it: the emitted wrappers name `RustCall.ffi_string_argument`,
and `4` adds `RustCall.FFIByValue`, neither of which earlier versions have. A
file at version `2` or below still loads — it uses only API that still exists —
but does not get the unload, panic-containment, lifetime, UTF-8 or by-value
guarantees described above.
