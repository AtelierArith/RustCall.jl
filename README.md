# LastCall.jl

**LastCall.jl** is a Foreign Function Interface (FFI) package for calling Rust code directly from Julia, inspired by [Cxx.jl](https://github.com/JuliaInterop/Cxx.jl).

> It's the last call for headache. 🦀

## Features

- **`@rust` macro**: Call Rust functions directly from Julia
- **`rust""` string literal**: Compile and load Rust code as shared libraries
- **`@irust` macro**: Execute Rust code at function scope
- **Type mapping**: Automatic conversion between Rust and Julia types
- **Result/Option support**: Handle Rust's `Result<T, E>` and `Option<T>` types

## Installation

```julia
using Pkg
Pkg.add("LastCall")
```

**Requirements:**
- Julia 1.10 or later
- Rust toolchain (`rustc` and `cargo`) installed and available in PATH

To install Rust, visit [rustup.rs](https://rustup.rs/).

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

**Note**: In Phase 1, `@irust` has limitations:
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

# Option type
some_opt = RustOption{Int32}(true, Int32(42))
is_some(some_opt)  # => true
unwrap(some_opt)   # => 42

none_opt = RustOption{Int32}(false, nothing)
is_none(none_opt)  # => true
unwrap_or(none_opt, Int32(0))  # => 0
```

## Architecture

LastCall.jl uses a two-phase approach:

### Phase 1: C-Compatible ABI (Current)

- Compiles Rust code to shared libraries (`.so`/`.dylib`/`.dll`)
- Uses `ccall` for function invocation
- Supports basic types and `extern "C"` functions

### Phase 2: LLVM IR Integration (Planned)

- Direct LLVM IR integration using `llvmcall`
- More efficient code generation
- Support for advanced Rust features

## Limitations

**Current limitations (Phase 1):**

- Only `extern "C"` functions are supported
- No generics support
- No lifetime/borrow checker integration
- Limited to basic types (no strings, arrays, etc. yet)

## Development Status

LastCall.jl is currently in **early development**. The basic functionality is working, but many features are still planned.

**Implemented:**
- ✅ Basic type mapping
- ✅ `rust""` string literal
- ✅ `@rust` macro
- ✅ `@irust` macro (basic, Phase 1)
- ✅ Result/Option types
- ✅ Basic error handling

**Planned:**
- ⏳ Enhanced `@irust` with better variable binding
- ⏳ String type support
- ⏳ Array/vector support
- ⏳ LLVM IR integration
- ⏳ Advanced error handling

## Examples

See the `test/` directory for more examples.

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
