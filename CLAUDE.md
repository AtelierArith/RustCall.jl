Read also AGENTS.md

# CLAUDE.md - LastCall.jl Development Guide

This document is a guide for developing **LastCall.jl**, a Foreign Function Interface (FFI) package based on Cxx.jl.

## Project Goals

Develop an FFI package called **LastCall.jl** that enables direct calls to Rust code from Julia.

### Features Provided

- `@rust` macro: Directly call Rust functions from Julia
- `rust""` string literal: Evaluate Rust code in global scope
- `irust""` string literal: Evaluate Rust code in function scope
- `#[julia]` attribute: Shorthand for `#[no_mangle] pub extern "C"`
- Integration with Rust's type system
- Optimization via LLVM IR

## Related Documents

| File | Content | Priority |
|------|---------|----------|
| `PLAN.md` | Overall plan, technical challenges, and solutions | ★★★ Required reading |
| `Phase1.md` | Phase 1 detailed implementation plan (C-compatible ABI) | ★★★ Required reading |
| `Phase2.md` | Phase 2 detailed implementation plan (LLVM IR integration) | ★★☆ Important |
| `INTERNAL.md` | Cxx.jl internal implementation details | ★★☆ Reference |
| `LLVMCALL.md` | Details on Julia `llvmcall` | ★★☆ Reference |
| `DESCRIPTION.md` | Cxx.jl overview | ★☆☆ Background knowledge |

## Development Phases

### Phase 1: C-Compatible ABI Integration (2-3 months)

**Goal**: Basic Rust-Julia interop using `extern "C"`

```
Julia (@rust macro)
    ↓
ccall wrapper generation
    ↓
Rust shared library (.so/.dylib/.dll)
    ↓
Rust function call
```

**Main Tasks**:
1. Create project structure
2. Basic type mapping (`i32` ↔ `Int32`, etc.)
3. Implement `@rust` macro (`ccall` wrapper)
4. `rust""` string literal (compile and load)
5. `Result<T, E>` → Julia exception conversion
6. Build test suite

**Deliverable**: Basic Rust function calls working

### Phase 2: LLVM IR Integration (4-6 months)

**Goal**: Direct integration at LLVM IR level

```
Julia (@rust macro)
    ↓
@generated function
    ↓
rustc (LLVM IR generation)
    ↓
LLVM.jl (IR manipulation)
    ↓
llvmcall embedding
    ↓
Julia JIT execution
```

**Main Tasks**:
1. LLVM.jl integration
2. rustc → LLVM IR pipeline
3. IR optimization and transformation
4. Embedding into `llvmcall`
5. Support for ownership types (`Box<T>`, `Arc<T>`)
6. Generics support

**Deliverable**: Optimized integration at LLVM IR level

### Phase 3: External Library Integration (Completed)

**Goal**: Integration of external crates using Cargo

- Dependency specification via `// cargo-deps:` format
- Automatic Cargo project generation
- Build caching

### Phase 4: Rust Struct Julia Objectification (Completed)

**Goal**: Use Rust structs directly in Julia

- Automatic detection of `pub struct`
- Automatic C-FFI wrapper generation
- Automatic Julia-side wrapper type generation
- Automatic memory management via finalizers

### Phase 5: `#[julia]` Attribute (Completed)

**Goal**: Simplify FFI function definitions

```rust
// Before: Verbose notation required
#[no_mangle]
pub extern "C" fn add(a: i32, b: i32) -> i32 { a + b }

// After: Concise with #[julia] attribute
#[julia]
fn add(a: i32, b: i32) -> i32 { a + b }
```

**Implementation file**: `src/julia_functions.jl`

**Main functions**:
- `parse_julia_functions(code)`: Detect functions with `#[julia]`
- `transform_julia_attribute(code)`: Transform `#[julia]` → `#[no_mangle] pub extern "C"`
- `emit_julia_function_wrappers(sigs)`: Automatically generate Julia-side wrapper functions

### Phase 6: rustc Internal API Integration (Experimental, not implemented)

**Goal**: Full Rust type system support

- Use rustc's internal API
- Integration with type inference and trait resolution
- Full generics support

**Note**: rustc API is unstable. Recommended for research purposes only.

## Technical Points

### Patterns to Learn from Cxx.jl

The following Cxx.jl code should be implemented with similar patterns in LastCall.jl:

1. **`llvmcall` pointer form** (`src/codegen.jl`)
```julia
# Core part of Cxx.jl
Expr(:call, Core.Intrinsics.llvmcall,
     convert(Ptr{Cvoid}, f),  # LLVM function pointer
     rett,                     # Return type
     Tuple{argt...},           # Argument types
     args2...)                 # Actual arguments
```

2. **Staged functions (@generated)**: Code generation at compile time based on type information

3. **Type mapping**: Bidirectional conversion between Julia types ↔ target language types

### Rust-Specific Challenges

| Challenge | Cxx.jl | LastCall.jl |
|-----------|--------|-------------|
| Compiler API | Clang (stable) | rustc (unstable) |
| Type system | C++ types | Ownership and lifetimes |
| Error handling | Exceptions | `Result<T, E>` |
| Memory management | Manual/RAII | Ownership system |

### Type Mapping (Phase 1)

```julia
# Rust → Julia
const RUST_JULIA_TYPE_MAP = Dict(
    "i8"    => Int8,
    "i16"   => Int16,
    "i32"   => Int32,
    "i64"   => Int64,
    "u8"    => UInt8,
    "u16"   => UInt16,
    "u32"   => UInt32,
    "u64"   => UInt64,
    "f32"   => Float32,
    "f64"   => Float64,
    "bool"  => Bool,
    "usize" => Csize_t,
    "isize" => Cssize_t,
    "()"    => Cvoid,
)
```

## Cxx.jl Source Code Reference

Files to reference when implementing LastCall.jl:

| Cxx.jl File | Role | LastCall.jl Equivalent |
|-------------|-----|----------------------|
| `src/cxxmacro.jl` | `@cxx` macro | `@rust` macro |
| `src/cxxstr.jl` | `cxx""` literal | `rust""` literal |
| `src/codegen.jl` | LLVM IR generation | LLVM IR integration |
| `src/typetranslation.jl` | Type conversion | Rust type conversion |
| `src/clangwrapper.jl` | Clang wrapper | rustc/cbindgen integration |
| `src/cxxtypes.jl` | C++ type definitions | Rust type definitions |

## Development Environment Setup

### Required Tools

```bash
# Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup component add rustfmt clippy

# Julia
julia --version  # 1.6+ recommended

# cbindgen (used in Phase 1)
cargo install cbindgen
```

### Project Creation

```bash
# Create a new Julia package
julia -e 'using Pkg; Pkg.generate("Rust")'
cd Rust

# Create Rust library
cargo new --lib deps/rustlib
```

## Implementation Hints

### Phase 1: Basic Form of @rust Macro

```julia
macro rust(lib, expr)
    # Parse function call
    func_name, args = parse_rust_call(expr)

    # Generate ccall
    quote
        ccall(
            ($(QuoteNode(func_name)), $lib),
            $(return_type),
            $(Tuple{arg_types...}),
            $(args...)
        )
    end
end
```

### Phase 2: Embedding into llvmcall

```julia
@generated function rust_call(::Type{Val{func_name}}, args...)
    # 1. Compile Rust code (reuse if cached)
    llvm_ir = compile_rust_to_llvm(func_name)

    # 2. Get LLVM function
    fn_ptr = get_function_pointer(llvm_ir, func_name)

    # 3. Generate llvmcall expression
    quote
        $(Expr(:call, Core.Intrinsics.llvmcall,
               fn_ptr, ret_type, Tuple{arg_types...}, args...))
    end
end
```

## Notes

1. **Cxx.jl supports Julia 1.3 and earlier**: Useful as reference, but won't work with latest Julia
2. **rustc API is unstable**: Phase 3 should be considered experimental
3. **Ownership handling**: Simplified with `extern "C"` in Phase 1, full support in Phase 2
4. **Write tests first**: TDD approach is safer
5. Use multiple dispatch actively. Write code in a Julia-like style.

## Reference Resources

- [Cxx.jl GitHub](https://github.com/JuliaInterop/Cxx.jl)
- [LLVM.jl](https://github.com/maleadt/LLVM.jl)
- [Rust FFI Guide](https://doc.rust-lang.org/nomicon/ffi.html)
- [cbindgen](https://github.com/mozilla/cbindgen)
- [Julia llvmcall Documentation](https://docs.julialang.org/en/v1/devdocs/llvm/)

## Next Steps

1. **Read PLAN.md**: Understand the overall picture
2. **Read Phase1.md**: Check specific implementation tasks
3. **Read INTERNAL.md**: Understand Cxx.jl implementation patterns
4. **Create project structure**: Start Phase 1
