# Precompilation Support

RustCall.jl supports Julia's precompilation system, enabling faster startup times for packages that use Rust bindings.

## Overview

When you use `@rust_crate` in a Julia package, the bindings can be precompiled along with your package. This avoids runtime compilation and significantly reduces startup time.

### Benefits

- **Faster startup**: Precompiled bindings load instantly
- **Deployment-ready**: No compilation needed at runtime
- **Reproducible builds**: Same bindings every time
- **PackageCompiler.jl compatible**: Works with standalone applications

## How It Works

### Runtime vs Precompile Time

**Without precompilation** (using `@rust_crate` directly):
1. Julia loads your package
2. `@rust_crate` scans the Rust crate
3. Rust code is compiled (if not cached)
4. Bindings are generated and evaluated

**With precompilation** (using `write_bindings_to_file`):
1. During development: Generate bindings file once
2. During precompilation: Julia compiles the bindings module
3. At runtime: Precompiled bindings load instantly

### The Generation Process

```
Rust Crate               Julia Bindings File
    │                           │
    ├── Cargo.toml              │
    ├── src/                    │
    │   └── lib.rs ──────────►  MyBindings.jl
    │                           │
    └── target/                 │
        └── release/            │
            └── lib*.so ◄───────┘
```

## Usage Guide

### Step 1: Project Structure

Set up your package with this structure:

```
MyPackage/
├── Project.toml
├── src/
│   ├── MyPackage.jl          # Main module
│   └── generated/
│       └── RustBindings.jl   # Generated bindings (gitignore this)
├── deps/
│   ├── my_rust_crate/        # Your Rust crate
│   │   ├── Cargo.toml
│   │   └── src/lib.rs
│   └── lib/                  # Compiled library location
│       └── libmy_rust_crate.{so,dylib,dll}
└── build.jl                  # Build script
```

### Step 2: Build Script

Create a `build.jl` to generate bindings:

```julia
# deps/build.jl
using RustCall

# Path to Rust crate
crate_path = joinpath(@__DIR__, "my_rust_crate")

# Output path for generated bindings
bindings_path = joinpath(dirname(@__DIR__), "src", "generated", "RustBindings.jl")

# Generate bindings
write_bindings_to_file(
    crate_path,
    bindings_path,
    output_module_name = "RustBindings",
    build_release = true,
    relative_lib_path = "../../deps/lib"
)
```

### Step 3: Package Module

Include the generated bindings in your package:

```julia
# src/MyPackage.jl
module MyPackage

# Include generated bindings
include("generated/RustBindings.jl")
using .RustBindings

# Re-export functions
export add, multiply, MyStruct

# Your Julia code here...

end
```

### Step 4: Build During Development

Run the build script during development:

```julia
using Pkg
Pkg.build("MyPackage")
```

Or manually:

```julia
include("deps/build.jl")
```

## PackageCompiler.jl Integration

RustCall.jl works with PackageCompiler.jl for creating standalone applications.

### Creating a System Image

```julia
using PackageCompiler

create_sysimage(
    :MyPackage,
    sysimage_path = "my_sysimage.so",
    precompile_execution_file = "precompile_script.jl"
)
```

### Creating an App

```julia
using PackageCompiler

create_app(
    ".",                    # Package directory
    "build",               # Output directory
    executables = ["main" => "main.jl"]
)
```

### Important Considerations

1. **Library Path**: Use `relative_lib_path` to ensure the compiled library is found relative to the bindings file
2. **Copy Library**: Ensure the compiled `.so`/`.dylib`/`.dll` is included in the app bundle
3. **Precompile Script**: Include calls to your Rust-backed functions in the precompile script

Example precompile script:

```julia
# precompile_script.jl
using MyPackage

# Warm up the functions
MyPackage.add(Int32(1), Int32(2))
MyPackage.multiply(1.0, 2.0)
```

## Cache Behavior

### During Development

- FirstCall.jl caches compiled libraries in `~/.julia/lastcall_cache/`
- Cache is keyed by source code hash
- Rebuilding only happens when source changes

### During Precompilation

- Generated bindings reference a fixed library path
- Library must exist at the specified path
- No runtime compilation occurs

### Cache Functions

```julia
# Clear the cache
clear_cache()

# Check cache size
get_cache_size()

# List cached libraries
list_cached_libraries()

# Clean up old cache entries
cleanup_old_cache(max_age_days=30)
```

## Troubleshooting

### Library Not Found

**Error**: `could not load library "..."` at runtime

**Solutions**:
1. Verify `relative_lib_path` points to the correct location
2. Check that the library was copied during build
3. Ensure the library has correct permissions

```julia
# Debug: Check the library path
bindings_dir = dirname(pathof(MyPackage))
lib_path = joinpath(bindings_dir, "..", "deps", "lib", "libmy_crate.so")
@info "Library exists?" isfile(lib_path)
```

### Precompilation Fails

**Error**: `LoadError` during precompilation

**Solutions**:
1. Ensure `__init__()` function loads the library correctly
2. Check that library path uses `@__DIR__` for portability
3. Verify the generated code syntax

### Version Mismatch

**Symptom**: Functions behave unexpectedly after updating Rust code

**Solution**: Regenerate bindings after modifying Rust code:

```julia
Pkg.build("MyPackage")
```

### Platform-Specific Issues

**macOS**:
- Library extension is `.dylib`
- May need to handle code signing

**Linux**:
- Library extension is `.so`
- Check `LD_LIBRARY_PATH` if needed

**Windows**:
- Library extension is `.dll`
- Place DLLs in the same directory as the Julia process or in PATH

## Best Practices

1. **Gitignore generated files**: Add `src/generated/` to `.gitignore`
2. **Version your Rust code**: Keep Rust crate under version control
3. **CI/CD integration**: Run `Pkg.build()` in CI to generate fresh bindings
4. **Test precompilation**: Include precompilation in your test suite
5. **Document dependencies**: Note Rust toolchain requirements in README

## Example: Complete Package

Here's a complete example of a precompilable package:

```julia
# Project.toml
name = "MyRustPackage"
uuid = "..."
version = "0.1.0"

[deps]
RustCall = "..."

[extras]
Test = "..."

[targets]
test = ["Test"]
```

```julia
# deps/build.jl
using RustCall

write_bindings_to_file(
    joinpath(@__DIR__, "rust_crate"),
    joinpath(dirname(@__DIR__), "src", "generated", "Bindings.jl"),
    output_module_name = "Bindings",
    relative_lib_path = "../../deps/lib"
)
```

```julia
# src/MyRustPackage.jl
module MyRustPackage

include("generated/Bindings.jl")
using .Bindings

export rust_add, rust_multiply

rust_add(a, b) = Bindings.add(Int32(a), Int32(b))
rust_multiply(a, b) = Bindings.multiply(Float64(a), Float64(b))

end
```

## See Also

- [External Crate Bindings](crate_bindings.md) - Full API reference
- [Julia Precompilation](https://docs.julialang.org/en/v1/manual/modules/#Module-initialization-and-precompilation) - Official Julia documentation
- [PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl) - Creating standalone applications
