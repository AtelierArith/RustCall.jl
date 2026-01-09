# LastCall.jl

**LastCall.jl** is a Foreign Function Interface (FFI) package for calling Rust code directly from Julia, inspired by [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl).

> It's the last call for headache. 🦀

## Features

### Phase 1: C-Compatible ABI ✅
- **`@rust` macro**: Call Rust functions directly from Julia
- **`rust""` string literal**: Compile and load Rust code as shared libraries
- **`@irust` macro**: Execute Rust code at function scope
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

## Installation

```julia
using Pkg
Pkg.add("LastCall")
```

**Requirements:**
- Julia 1.10 or later
- Rust toolchain (`rustc` and `cargo`) installed and available in PATH

To install Rust, visit [rustup.rs](https://rustup.rs/).

### Building Rust Helpers Library

For full functionality including ownership types (Box, Rc, Arc), you need to build the Rust helpers library:

```julia
using Pkg
Pkg.build("LastCall")
```

Or from the command line:

```bash
julia --project -e 'using Pkg; Pkg.build("LastCall")'
```

This will compile the Rust helpers library that provides FFI functions for ownership types.

## Quick Start

### Basic Usage

```julia
using LastCall

# Define and compile Rust code
rust"""
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 {
    a + b
}
"""

# Call the Rust function
result = @rust add(Int32(10), Int32(20))::Int32
println(result)  # => 30
```

### With Explicit Return Type

```julia
rust"""
#[no_mangle]
pub extern "C" fn multiply(x: f64, y: f64) -> f64 {
    x * y
}
"""

# Specify return type explicitly
result = @rust multiply(3.0, 4.0)::Float64
println(result)  # => 12.0
```

### Boolean Functions

```julia
rust"""
#[no_mangle]
pub extern "C" fn is_positive(x: i32) -> bool {
    x > 0
}
"""

@rust is_positive(Int32(5))::Bool   # => true
@rust is_positive(Int32(-5))::Bool # => false
```

### Function Scope Execution (`@irust`)

The `@irust` macro allows you to execute Rust code at function scope:

```julia
function double(x)
    @irust("arg1 * 2", x)
end

result = double(21)  # => 42
```

**Note**: Current limitations:
- Arguments must be passed explicitly
- Code should use `arg1`, `arg2`, etc. to reference arguments
- Return type is inferred from the code

## Type Mapping

LastCall.jl automatically maps Rust types to Julia types:

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

LastCall.jl supports passing Julia strings to Rust functions expecting C strings:

```julia
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

LastCall.jl provides Julia wrappers for Rust's `Result<T, E>` and `Option<T>` types:

```julia
using LastCall

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

LastCall.jl provides Julia wrappers for Rust's ownership types. These require the Rust helpers library to be built:

```julia
using LastCall

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

**Note**: Ownership types require the Rust helpers library. Build it with `Pkg.build("LastCall")`.

### Array and Collection Operations

LastCall.jl provides full support for array operations on `RustVec` and `RustSlice`:

```julia
using LastCall

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

**Note**: Creating `RustVec` from Julia `Vector` requires the Rust helpers library and is currently being implemented.

## LLVM IR Integration (Phase 2, Experimental)

LastCall.jl supports direct LLVM IR integration for optimized function calls:

```julia
using LastCall

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
using LastCall

# Create optimization config
config = OptimizationConfig(
    level=3,  # Optimization level 0-3
    enable_vectorization=true,
    inline_threshold=300
)

# Optimize a module
optimize_module!(module, config)

# Convenience functions
optimize_for_speed!(module)  # Level 3, aggressive optimizations
optimize_for_size!(module)   # Level 2, size optimizations
```

## Compilation Caching

LastCall.jl uses a SHA256-based caching system to avoid recompiling unchanged Rust code:

```julia
using LastCall

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

LastCall.jl uses a two-phase approach:

### Phase 1: C-Compatible ABI ✅ (Complete)

- Compiles Rust code to shared libraries (`.so`/`.dylib`/`.dll`)
- Uses `ccall` for function invocation
- Supports basic types and `extern "C"` functions
- SHA256-based compilation caching
- String type support

### Phase 2: LLVM IR Integration ✅ (Major Features Complete)

- Direct LLVM IR integration using `llvmcall` (experimental)
- LLVM optimization passes
- Ownership types (Box, Rc, Arc, Vec, Slice)
- Function registration system
- Enhanced error handling

## Current Limitations

**Phase 1 limitations:**
- Only `extern "C"` functions are supported
- No lifetime/borrow checker integration
- Array/vector indexing and iteration supported ✅
- Creating RustVec from Julia Vector requires Rust helpers library

**Generics support (Phase 2):**
- ✅ Generic function detection and registration
- ✅ Automatic monomorphization
- ✅ Type parameter inference from arguments
- ✅ Caching of monomorphized instances
- ⚠️ Trait bounds parsing is simplified (basic support)

**Phase 2 limitations:**
- `@rust_llvm` is experimental and may have limitations
- Ownership types require Rust helpers library to be built
- Some advanced Rust features are not yet supported

**Error handling (Phase 2):**
- ✅ Enhanced compilation error display with line numbers and suggestions
- ✅ Debug mode with detailed logging and intermediate file preservation
- ✅ Automatic error suggestions for common issues
- ✅ Improved runtime error messages with stack traces

## Development Status

LastCall.jl has completed **Phase 1** and **Phase 2 major features**. The package is functional for basic to intermediate use cases.

**Implemented:**
- ✅ Basic type mapping
- ✅ `rust""` string literal
- ✅ `@rust` macro
- ✅ `@irust` macro
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

**In Progress:**
- 🚧 Ownership types full integration (requires Rust helpers library compilation)
- 🚧 Enhanced `@irust` with better variable binding

**Recently Completed:**
- ✅ Array/collection operations (indexing, iteration, conversion)
- ✅ RustVec creation from Julia Vector (requires Rust helpers library)
- ✅ Generics support (monomorphization, type parameter inference)

**Planned:**
- ⏳ Generics support
- ⏳ Lifetime/borrow checker integration
- ⏳ Advanced Rust features

## Examples

### Example Scripts

Run the example scripts to see LastCall.jl in action:

```bash
# Basic examples
julia --project examples/basic_examples.jl

# Advanced examples (generics, arrays, LLVM optimization)
julia --project examples/advanced_examples.jl

# Ownership types examples (requires Rust helpers library)
julia --project examples/ownership_examples.jl
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

## Performance

LastCall.jl includes a benchmark suite comparing Julia native, `@rust`, and `@rust_llvm`:

```bash
julia --project benchmark/benchmarks.jl
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License (see LICENSE file)

## Acknowledgments

- Inspired by [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl)
- Built with [LLVM.jl](https://github.com/maleadt/LLVM.jl)

## Related Projects

- [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl) - C++ FFI for Julia
- [CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl) - Modern C++ wrapper generator
- [RustCall.jl](https://github.com/JuliaInterop/RustCall.jl) - Another Rust FFI project (different approach)

## Documentation

### User Documentation

- **[Tutorial](docs/TUTORIAL.md)** - Step-by-step guide to using LastCall.jl
  - Basic usage and type system
  - String handling and error handling
  - Ownership types and LLVM IR integration
  - Performance optimization tips

- **[Examples](docs/EXAMPLES.md)** - Practical examples and use cases
  - Numerical computations
  - String processing
  - Data structures
  - Performance comparisons
  - Real-world examples

- **[Performance Guide](docs/src/performance.md)** - Performance optimization guide (日本語)
  - Compilation caching
  - LLVM optimization
  - Function call optimization
  - Memory management
  - Benchmark results
  - Performance tuning tips

- **[Troubleshooting Guide](docs/troubleshooting.md)** - Common issues and solutions (日本語)
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
