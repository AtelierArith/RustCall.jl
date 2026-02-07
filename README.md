# RustCall.jl

[![CI](https://github.com/atelierarith/RustCall.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/atelierarith/RustCall.jl/actions/workflows/CI.yml)

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/AtelierArith/RustCall.jl)

**RustCall.jl** is a Foreign Function Interface (FFI) package for calling Rust code directly from Julia, inspired by [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl).

> It's the last call for headache. 🦀

## Features

### Phase 1: C-Compatible ABI ✅
- **`@rust` macro**: Call Rust functions directly from Julia
- **`rust""` string literal**: Compile and load Rust code as shared libraries
- **`@irust` macro**: Execute Rust code at function scope with `$var` variable binding
- **Type mapping**: Automatic conversion between Rust and Julia types
- **Result/Option support**: Handle Rust's `Result<T, E>` and `Option<T>` types
- **String support**: Pass Julia strings to Rust functions expecting C strings
- **Compilation caching**: SHA256-based caching system for compiled libraries

### Phase 2: LLVM IR Integration ✅
- **`@rust_llvm` macro**: Direct LLVM IR integration (experimental)
- **LLVM optimization**: Configurable optimization passes
- **Ownership types**: `RustBox`, `RustRc`, `RustArc`, `RustVec`, `RustSlice`
- **Array operations**: Indexing, iteration, Julia ↔ Rust conversion
- **Generics support**: Automatic monomorphization and type parameter inference
- **Error handling**: `RustError` exception type with `result_to_exception`
- **Function registration**: Register and cache compiled Rust functions

### Phase 3: External Library Integration ✅
- **Cargo support**: Automatically download and build external crates
- **Dependency parsing**: Support for `//! ```cargo ... ``` ` and `// cargo-deps:` formats
- **Cached builds**: Intelligent caching of Cargo projects to minimize rebuild times
- **Crate integration**: Easily use popular crates like `ndarray`, `serde`, `rand`, etc.

### Phase 4: Rust Structs as Julia Objects ✅
- **Automatic mapping**: Detect `pub struct` and `pub fn` to generate Julia wrappers
- **C-FFI generation**: Automatically create "extern C" wrappers for Rust methods
- **Dynamic Julia types**: Generate `mutable struct` in Julia at macro expansion time
- **Automatic memory management**: Integrated `finalizer` that calls Rust's `Drop` implementation
- **Managed lifecycle**: Seamlessly use Rust objects as first-class citizens in Julia

### Phase 5: `#[julia]` Attribute ✅
- **Simplified FFI**: Use `#[julia]` instead of `#[no_mangle] pub extern "C"`
- **Auto-wrapper generation**: Julia wrapper functions are automatically created
- **Type inference**: Automatic Julia type conversion based on Rust types
- **Zero boilerplate**: No need to manually define Julia wrapper functions

### Phase 6: External Crate Bindings (Maturin-like) ✅
- **`lastcall_macros` crate**: Proc-macro crate for `#[julia]` attribute (publishable to crates.io)
- **`@rust_crate` macro**: Automatically generate Julia bindings for external Rust crates
- **Crate scanning**: Detect `#[julia]` marked functions and structs in external crates
- **Automatic building**: Build external crates and generate Julia modules
- **Caching**: Cache compiled libraries for faster subsequent loads

## Requirements:

- Julia 1.12 or later

### Building Rust Helpers Library

For full functionality including ownership types (Box, Rc, Arc), you need to build the Rust helpers library:

```julia
using Pkg
Pkg.build()
```

Or from the command line:

```bash
julia --project -e 'using Pkg; Pkg.build()'
```

This will compile the Rust helpers library that provides FFI functions for ownership types.

## Quick Start

### 1. Define and Call Rust Functions (Simple Way)

```julia
using RustCall

# Use #[julia] attribute - no boilerplate needed!
rust"""
#[julia]
fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

# Call directly - wrapper is auto-generated
add(10, 20)  # => 30
```

### 2. Traditional FFI (Full Control)

```julia
using RustCall

# Traditional way with explicit FFI markers
rust"""
#[no_mangle]
pub extern "C" fn multiply(a: i32, b: i32) -> i32 {
    a * b
}
"""

# Call with @rust macro and explicit types
@rust multiply(Int32(5), Int32(7))::Int32  # => 35
```

### 3. Inline Rust with `@irust`

Execute Rust code directly with automatic variable binding:

```julia
function compute(x, y)
    @irust("\$x * \$y + 10")
end

compute(Int32(3), Int32(4))  # => 22
```

### 4. Use External Crates

Leverage the Rust ecosystem with automatic Cargo integration:

```julia
rust"""
// cargo-deps: rand = "0.8"

use rand::Rng;

#[no_mangle]
pub extern "C" fn random_number() -> i32 {
    rand::thread_rng().gen_range(1..=100)
}
"""

@rust random_number()::Int32  # => random number 1-100
```

### 5. Rust Structs as Julia Objects

Define Rust structs and use them as first-class Julia types:

```julia
rust"""
#[julia]
pub struct Counter {
    value: i32,
}

impl Counter {
    pub fn new(initial: i32) -> Self {
        Self { value: initial }
    }

    pub fn increment(&mut self) {
        self.value += 1;
    }

    pub fn get(&self) -> i32 {
        self.value
    }
}
"""

counter = Counter(0)
increment(counter)
increment(counter)
get(counter)  # => 2
```

### More Examples

```julia
# Float operations
rust"""
#[no_mangle]
pub extern "C" fn circle_area(radius: f64) -> f64 {
    std::f64::consts::PI * radius * radius
}
"""
@rust circle_area(2.0)::Float64  # => 12.566370614359172

# Boolean functions
rust"""
#[no_mangle]
pub extern "C" fn is_even(n: i32) -> bool {
    n % 2 == 0
}
"""
@rust is_even(Int32(42))::Bool  # => true

# Multiple variables with @irust
function quadratic(a, b, c, x)
    @irust("\$a * \$x * \$x + \$b * \$x + \$c")
end
quadratic(1.0, 2.0, 1.0, 3.0)  # => 16.0 (x² + 2x + 1 at x=3)
```

### 6. Image Processing with Rust

Process images using Rust for performance-critical operations:

```julia
using RustCall
using Images

# Define Rust grayscale conversion
rust"""
#[no_mangle]
pub extern "C" fn grayscale_image(pixels: *mut u8, width: usize, height: usize) {
    let slice = unsafe { std::slice::from_raw_parts_mut(pixels, width * height * 3) };
    for i in 0..(width * height) {
        let r = slice[i * 3] as f32;
        let g = slice[i * 3 + 1] as f32;
        let b = slice[i * 3 + 2] as f32;
        let gray = (0.299 * r + 0.587 * g + 0.114 * b) as u8;
        slice[i * 3] = gray;
        slice[i * 3 + 1] = gray;
        slice[i * 3 + 2] = gray;
    }
}
"""

# Process image data
pixels = vec(rand(UInt8, 256 * 256 * 3))
@rust grayscale_image(pointer(pixels), UInt(256), UInt(256))::Cvoid
```

### 7. External Crate Bindings (Maturin-like)

Generate Julia bindings for external Rust crates using `@rust_crate`:

**Rust side (external crate):**
```rust
// Cargo.toml needs: lastcall_macros = "0.1"
use lastcall_macros::julia;

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
        Point { x, y }
    }

    #[julia]
    pub fn distance(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}
```

**Julia side:**
```julia
using RustCall

# Generate bindings from external crate
@rust_crate "/path/to/my_crate"

# Use the generated module
MyCrate.add(1, 2)  # => 3
p = MyCrate.Point(3.0, 4.0)
MyCrate.distance(p)  # => 5.0
```

## Type Mapping

RustCall.jl automatically maps Rust types to Julia types:

| Rust Type | Julia Type |
|-----------|------------|
| `i8`      | `Int8`     |
| `i16`     | `Int16`    |
| `i32`     | `Int32`    |
| `i64`     | `Int64`    |
| `u8`      | `UInt8`    |
| `u16`     | `UInt16`   |
| `u32`     | `UInt32`   |
| `u64`     | `UInt64`   |
| `f32`     | `Float32`  |
| `f64`     | `Float64`  |
| `bool`    | `Bool`     |
| `usize`   | `UInt`     |
| `isize`   | `Int`      |
| `()`      | `Cvoid`    |
| `*const u8` | `Cstring` / `String` |
| `*mut u8` | `Ptr{UInt8}` |

## String Support

RustCall.jl supports passing Julia strings to Rust functions expecting C strings:

```julia
using RustCall

rust"""
#[no_mangle]
pub extern "C" fn string_length(s: *const u8) -> u32 {
    let c_str = unsafe { std::ffi::CStr::from_ptr(s as *const i8) };
    c_str.to_bytes().len() as u32
}
"""

# Julia String is automatically converted to Cstring
result = @rust string_length("hello")::UInt32  # => 5

# UTF-8 strings are supported
result = @rust string_length("世界")::UInt32   # => 6 (UTF-8 bytes)
```

## Result and Option Types

RustCall.jl provides Julia wrappers for Rust's `Result<T, E>` and `Option<T>` types:

```julia
using RustCall

# Result type
ok_result = RustResult{Int32, String}(true, Int32(42))
is_ok(ok_result)  # => true
unwrap(ok_result)  # => 42

err_result = RustResult{Int32, String}(false, "error")
is_err(err_result)  # => true
unwrap_or(err_result, Int32(0))  # => 0

# Convert Result to exception
try
    result_to_exception(err_result)
catch e
    println(e isa RustError)  # => true
end

# Option type
some_opt = RustOption{Int32}(true, Int32(42))
is_some(some_opt)  # => true
unwrap(some_opt)   # => 42

none_opt = RustOption{Int32}(false, nothing)
is_none(none_opt)  # => true
unwrap_or(none_opt, Int32(0))  # => 0
```

## Ownership Types (Phase 2)

RustCall.jl provides Julia wrappers for Rust's ownership types. These require the Rust helpers library to be built:

```julia
using RustCall

# Check if Rust helpers library is available
if is_rust_helpers_available()
    # RustBox - heap-allocated value (single ownership)
    box = RustBox(Int32(42))
    @test is_valid(box)
    drop!(box)  # Explicitly drop
    @test is_dropped(box)

    # RustRc - reference counting (single-threaded)
    rc1 = RustRc(Int32(100))
    rc2 = clone(rc1)  # Increment reference count
    drop!(rc1)  # Still valid because rc2 holds a reference
    @test is_valid(rc2)
    drop!(rc2)

    # RustArc - atomic reference counting (thread-safe)
    arc1 = RustArc(Int32(200))
    arc2 = clone(arc1)  # Thread-safe clone
    drop!(arc1)
    @test is_valid(arc2)
    drop!(arc2)

    # RustVec - growable array
    vec = RustVec{Int32}(ptr, len, cap)
    @test length(vec) == len

    # RustSlice - slice view
    slice = RustSlice{Int32}(ptr, len)
    @test length(slice) == len
end
```

**Note**: Ownership types require the Rust helpers library. Build it with `Pkg.build("RustCall")`.

### Array and Collection Operations

RustCall.jl provides full support for array operations on `RustVec` and `RustSlice`:

```julia
using RustCall

# Indexing (1-based, like Julia arrays)
vec = RustVec{Int32}(ptr, 10, 20)
value = vec[1]      # Get first element
vec[1] = 42         # Set first element

# Bounds checking
try
    vec[0]  # Throws BoundsError
catch e
    println(e isa BoundsError)  # => true
end

# Iteration
for x in vec
    println(x)
end

# Convert to Julia Vector (copies data)
julia_vec = Vector(vec)  # or collect(vec)
println(julia_vec)  # => [1, 2, 3, ...]

# RustSlice - read-only view
slice = RustSlice{Int32}(ptr, 5)
value = slice[1]    # Get element
for x in slice
    println(x)
end

# Iterator traits
@test Base.IteratorSize(RustVec{Int32}) == Base.HasLength()
@test Base.eltype(RustVec{Int32}) == Int32
```

**Note**: Creating `RustVec` from Julia `Vector` requires the Rust helpers library. Use `create_rust_vec()` to convert Julia arrays to RustVec.

## LLVM IR Integration (Phase 2, Experimental)

RustCall.jl supports direct LLVM IR integration for optimized function calls:

```julia
using RustCall

# Compile and register a Rust function
rust"""
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

# Register for LLVM integration
info = compile_and_register_rust_function("""
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 { a + b }
""", "add")

# Use @rust_llvm for optimized calls
result = @rust_llvm add(Int32(10), Int32(20))  # => 30
```

### LLVM Optimization

Configure optimization passes:

```julia
using RustCall

# Compile Rust code to LLVM IR
rust_code = """
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

wrapped_code = RustCall.wrap_rust_code(rust_code)
compiler = get_default_compiler()
ir_path = RustCall.compile_rust_to_llvm_ir(wrapped_code; compiler=compiler)

# Load the LLVM IR module
rust_mod = RustCall.load_llvm_ir(ir_path; source_code=wrapped_code)
llvm_mod = rust_mod.mod  # Get the LLVM.Module

# Create optimization config
config = OptimizationConfig(
    level=3,  # Optimization level 0-3
    enable_vectorization=true,
    inline_threshold=300
)

# Optimize the module
optimize_module!(llvm_mod; config=config)

# Convenience functions
optimize_for_speed!(llvm_mod)  # Level 3, aggressive optimizations
optimize_for_size!(llvm_mod)   # Level 2, size optimizations
```

## External Library Integration (Phase 3)

RustCall.jl supports using external Rust crates directly in `rust""` blocks. Dependencies are automatically downloaded and built using Cargo.

### Basic Usage

```julia
using RustCall

# Use external crates with cargo-deps format
rust"""
// cargo-deps: ndarray = "0.15"

use ndarray::Array1;

#[no_mangle]
pub extern "C" fn compute_sum(data: *const f64, len: usize) -> f64 {
    unsafe {
        let slice = std::slice::from_raw_parts(data, len);
        let arr = Array1::from_vec(slice.to_vec());
        arr.sum()
    }
}
"""

# Call with Julia array
data = [1.0, 2.0, 3.0, 4.0, 5.0]
result = @rust compute_sum(pointer(data), length(data))::Float64
println(result)  # => 15.0
```

### Dependency Formats

RustCall.jl supports multiple dependency specification formats:

**Format 1: cargo-deps comment**
```rust
// cargo-deps: serde = "1.0", serde_json = "1.0"
```

**Format 2: rustscript-style code block**
```rust
//! ```cargo
//! [dependencies]
//! rand = "0.8"
//! ```
```

### Cargo Project Management

```julia
using RustCall

# Dependencies are automatically parsed and built
rust"""
// cargo-deps: serde = { version = "1.0", features = ["derive"] }

use serde::{Serialize, Deserialize};

#[derive(Serialize, Deserialize)]
pub struct Data {
    value: i32,
}

#[no_mangle]
pub extern "C" fn process_data(val: i32) -> i32 {
    let data = Data { value: val };
    data.value * 2
}
"""

result = @rust process_data(Int32(21))::Int32
```

**Note**: First-time builds may take longer as dependencies are downloaded and compiled. Subsequent builds use cached artifacts.

## Rust Structs as Julia Objects (Phase 4)

RustCall.jl automatically detects `pub struct` definitions and generates Julia wrappers, allowing you to use Rust objects as first-class Julia types.

### Basic Struct Usage

```julia
using RustCall

# Define a Rust struct with methods
rust"""
pub struct Person {
    age: u32,
    height: f64,
}

impl Person {
    pub fn new(age: u32, height: f64) -> Self {
        Self { age, height }
    }

    pub fn greet(&self) {
        println!("Hello, I am {} years old.", self.age);
    }

    pub fn have_birthday(&mut self) {
        self.age += 1;
    }

    pub fn get_height(&self) -> f64 {
        self.height
    }
}
"""

# Use as a Julia type
person = Person(30, 175.5)
greet(person)
have_birthday(person)
height = get_height(person)
```

### Generic Structs

```julia
using RustCall

rust"""
pub struct Point<T> {
    x: T,
    y: T,
}

impl<T> Point<T> {
    pub fn new(x: T, y: T) -> Self {
        Self { x, y }
    }
}

impl Point<f64> {
    pub fn distance(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}
"""

# Use with explicit type parameters
point = Point{Float64}(3.0, 4.0)
dist = distance(point)  # => 5.0
```

### Memory Management

Rust structs are automatically managed with finalizers that call Rust's `Drop` implementation:

```julia
using RustCall

rust"""
pub struct Resource {
    data: Vec<u8>,
}

impl Resource {
    pub fn new(size: usize) -> Self {
        Self {
            data: vec![0; size],
        }
    }
}

impl Drop for Resource {
    fn drop(&mut self) {
        println!("Rust: Dropping Resource");
    }
}
"""

# Resource is automatically cleaned up when it goes out of scope
function use_resource()
    res = Resource(1000)
    # ... use resource ...
    # Drop is called automatically when res goes out of scope
end
```

## Compilation Caching

RustCall.jl uses a SHA256-based caching system to avoid recompiling unchanged Rust code:

```julia
using RustCall

# Cache is automatically used
rust"""
#[no_mangle]
pub extern "C" fn test() -> i32 { 42 }
"""

# Second compilation uses cache
rust"""
#[no_mangle]
pub extern "C" fn test() -> i32 { 42 }
"""

# Cache management
clear_cache()  # Clear all cached libraries
get_cache_size()  # Get cache size in bytes
list_cached_libraries()  # List all cached library keys
cleanup_old_cache(30)  # Remove entries older than 30 days
```

## Architecture

RustCall.jl uses a multi-phase approach:

### Phase 1: C-Compatible ABI ✅ (Complete)

- Compiles Rust code to shared libraries (`.so`/`.dylib`/`.dll`)
- Uses `ccall` for function invocation
- Supports basic types and `extern "C"` functions
- SHA256-based compilation caching
- String type support
- `@irust` macro with `$var` variable binding syntax

### Phase 2: LLVM IR Integration ✅ (Complete)

- Direct LLVM IR integration using `llvmcall` (experimental)
- LLVM optimization passes
- Ownership types (Box, Rc, Arc, Vec, Slice)
- Function registration system
- Enhanced error handling
- Generics support with automatic monomorphization

### Phase 3: External Library Integration ✅ (Complete)

- Automatic Cargo project generation
- Dependency parsing and resolution
- Cached Cargo builds
- Integration with popular crates (ndarray, serde, rand, etc.)

### Phase 4: Rust Structs as Julia Objects ✅ (Complete)

- Automatic struct detection and wrapper generation
- C-FFI wrapper generation for methods
- Dynamic Julia type generation
- Automatic memory management with finalizers

### Phase 5: `#[julia]` Attribute ✅ (Complete)

- `#[julia]` attribute for simplified FFI function definition
- Automatic transformation to `#[no_mangle] pub extern "C"`
- Julia wrapper function auto-generation
- Seamless type conversion

### Phase 6: External Crate Bindings (Maturin-like) ✅ (Complete)

- `lastcall_macros` proc-macro crate for `#[julia]` attribute
- `@rust_crate` macro for automatic binding generation
- Crate scanning to detect `#[julia]` marked items
- Automatic Cargo build integration
- Library caching for fast subsequent loads

## Current Limitations

**Phase 1 limitations:**
- Only `extern "C"` functions are supported
- No lifetime/borrow checker integration
- Array/vector indexing and iteration supported ✅
- Creating RustVec from Julia Vector requires Rust helpers library (use `create_rust_vec()`)

**Phase 2 limitations:**
- `@rust_llvm` is experimental and may have limitations
- Ownership types require Rust helpers library to be built (`Pkg.build("RustCall")`)
- Some advanced Rust features are not yet supported

**Generics support (Phase 2):**
- ✅ Generic function detection and registration
- ✅ Automatic monomorphization
- ✅ Type parameter inference from arguments
- ✅ Caching of monomorphized instances
- ✅ Enhanced trait bounds parsing (inline bounds, where clauses, generic traits)

**Phase 3 limitations:**
- Cargo builds are cached but may take time on first use
- Complex dependency resolution may require manual intervention
- Some crates may require additional build configuration
- Platform-specific dependencies may not work on all systems

**Phase 4 limitations:**
- Generic structs require explicit type parameters when calling from Julia
- Complex trait bounds may not be fully supported
- Nested structs and advanced Rust patterns may require manual FFI code
- Associated types and advanced trait features are not yet supported

**Error handling:**
- ✅ Enhanced compilation error display with line numbers and suggestions
- ✅ Debug mode with detailed logging and intermediate file preservation
- ✅ Automatic error suggestions for common issues
- ✅ Improved runtime error messages with stack traces

## Development Status

RustCall.jl has completed **Phase 1 through Phase 6**. The package is fully functional for production use cases.

**Implemented:**
- ✅ Basic type mapping
- ✅ `rust""` string literal
- ✅ `@rust` macro
- ✅ `@irust` macro with `$var` variable binding
- ✅ Result/Option types
- ✅ Error handling (`RustError`, `result_to_exception`)
- ✅ String type support
- ✅ Compilation caching
- ✅ LLVM IR integration (`@rust_llvm`)
- ✅ LLVM optimization passes
- ✅ Ownership types (Box, Rc, Arc, Vec, Slice)
- ✅ Array operations (indexing, iteration, conversion)
- ✅ Generics support (monomorphization, type inference)
- ✅ Function registration system
- ✅ Rust helpers library build system
- ✅ External crate integration (Cargo dependencies)
- ✅ Automatic struct wrapper generation
- ✅ Method binding for Rust structs
- ✅ `#[julia]` attribute for simplified FFI
- ✅ `@rust_crate` macro for external crate bindings
- ✅ `lastcall_macros` proc-macro crate

**Recently Completed:**
- ✅ Phase 3: External library integration (Cargo, ndarray, etc.)
- ✅ Phase 4: Rust structs as Julia objects
- ✅ Phase 5: `#[julia]` attribute for simplified FFI
- ✅ Phase 6: External crate bindings (Maturin-like feature)
- ✅ Generic struct support with automatic monomorphization
- ✅ Enhanced error handling with suggestions
- ✅ Enhanced `@irust` with `$var` variable binding syntax
- ✅ Enhanced trait bounds parsing for generics (inline bounds, where clauses, generic traits)

**Planned:**
- ⏳ Lifetime/borrow checker integration
- ⏳ CI/CD pipeline and package distribution
- ⏳ `lastcall_macros` crate publication to crates.io

## Examples

### Example Scripts

Run the example scripts to see RustCall.jl in action:

```bash
# Basic examples
julia --project examples/basic_examples.jl

# Advanced examples (generics, arrays, LLVM optimization)
julia --project examples/advanced_examples.jl

# Ownership types examples (requires Rust helpers library)
julia --project examples/ownership_examples.jl

# Struct automation examples (Phase 4)
julia --project examples/struct_examples.jl

# External crate integration (Phase 3)
julia --project examples/phase4_ndarray.jl
julia --project examples/phase4_pi.jl
```

### Test Suite

See the `test/` directory for comprehensive examples:
- `test/runtests.jl` - Main test suite
- `test/test_cache.jl` - Caching tests
- `test/test_ownership.jl` - Ownership types tests
- `test/test_arrays.jl` - Array and collection operations tests
- `test/test_llvmcall.jl` - LLVM integration tests
- `test/test_generics.jl` - Generics support tests
- `test/test_error_handling.jl` - Error handling tests
- `test/test_rust_helpers_integration.jl` - Rust helpers library integration tests
- `test/test_docs_examples.jl` - Documentation examples validation tests
- `test/test_dependencies.jl` - Dependency parsing tests (Phase 3)
- `test/test_cargo.jl` - Cargo project generation tests (Phase 3)
- `test/test_ndarray.jl` - External crate integration tests (Phase 3)
- `test/test_phase4.jl` - Struct automation tests (Phase 4)
- `test/test_julia_attribute.jl` - `#[julia]` attribute tests (Phase 5)
- `test/test_crate_bindings.jl` - External crate bindings tests (Phase 6)

## Performance

RustCall.jl includes a comprehensive benchmark suite:

```bash
# Basic performance benchmarks
julia --project benchmark/benchmarks.jl

# LLVM integration benchmarks
julia --project benchmark/benchmarks_llvm.jl

# Array operation benchmarks
julia --project benchmark/benchmarks_arrays.jl

# Generics benchmarks
julia --project benchmark/benchmarks_generics.jl

# Ownership type benchmarks
julia --project benchmark/benchmarks_ownership.jl
```

The benchmarks compare Julia native implementations against `@rust` (ccall) and `@rust_llvm` (LLVM IR integration) approaches.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License (see LICENSE file)

## Acknowledgments

- Inspired by [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl)
- Built with [LLVM.jl](https://github.com/maleadt/LLVM.jl)
- Developed with AI assistance from Claude Code, Codex, Cursor, and Antigravity

## Related Projects

- [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl) - C++ FFI for Julia
- [CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl) - Modern C++ wrapper generator

## Documentation

### User Documentation

- **[Tutorial](docs/src/tutorial.md)** - Step-by-step guide to using RustCall.jl
  - Basic usage and type system
  - String handling and error handling
  - Ownership types and LLVM IR integration
  - Performance optimization tips

- **[Examples](docs/src/examples.md)** - Practical examples and use cases
  - Numerical computations
  - String processing
  - Data structures
  - Performance comparisons
  - Real-world examples

- **[Generics Guide](docs/src/generics.md)** - Generics support and usage
  - Generic function detection
  - Automatic monomorphization
  - Type parameter inference
  - Caching of monomorphized instances

- **[Performance Guide](docs/src/performance.md)** - Performance optimization guide
  - Compilation caching
  - LLVM optimization
  - Function call optimization
  - Memory management
  - Benchmark results
  - Performance tuning tips

- **[Troubleshooting Guide](docs/src/troubleshooting.md)** - Common issues and solutions
  - Installation and setup problems
  - Compilation errors
  - Runtime errors
  - Type-related issues
  - Memory management problems
  - Performance issues
  - Frequently asked questions

### Development Documentation

- `docs/STATUS.md` - Project status and implementation details
- `docs/design/Phase1.md` - Phase 1 implementation plan
- `docs/design/Phase2.md` - Phase 2 implementation plan
- `CLAUDE.md` - Development guide for AI agents
