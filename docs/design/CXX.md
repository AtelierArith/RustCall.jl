# CLAUDE.md - Project Guide

This document is a guide for Claude to understand and effectively assist with this project.

## Project Overview

**Cxx.jl** is an FFI (Foreign Function Interface) package for directly calling C++ code from Julia.

### Main Features

- `@cxx` macro: Directly call C++ functions from Julia
- `cxx""` string literal: Evaluate C++ code in global scope
- `icxx""` string literal: Evaluate C++ code in function scope
- C++ REPL: Add C++ REPL panel to Julia REPL

### Current Status

- **Supported Versions**: Julia 1.1.x to 1.3.x (currently unsupported)
- For newer Julia versions, [CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl) is recommended

## Directory Structure

```
Cxx.jl/
├── src/                    # Main source code
│   ├── Cxx.jl              # Main module
│   ├── cxxmacro.jl         # @cxx macro implementation
│   ├── cxxstr.jl           # cxx"" and icxx"" implementation
│   ├── cxxtypes.jl         # C++ type Julia representation
│   ├── typetranslation.jl  # Type conversion logic
│   ├── codegen.jl          # LLVM IR code generation
│   ├── clangwrapper.jl     # Clang API wrapper
│   ├── clanginstances.jl   # Clang instance management
│   ├── initialization.jl   # Initialization processing
│   ├── exceptions.jl       # C++ exception handling
│   └── CxxREPL/            # C++ REPL functionality
├── deps/                   # Build scripts and LLVM patches
├── docs/                   # Documentation
├── test/                   # Test suite
└── Documentation (.md)
```

## Important Documents

| File | Content |
|------|---------|
| `DESCRIPTION.md` | Project overview |
| `INTERNAL.md` | Internal implementation details (C++ code processing flow) |
| `LLVMCALL.md` | Details about Julia's `llvmcall` |
| `PLAN.md` | LastCall.jl implementation plan |
| `Phase1.md` | Phase 1 (C-compatible ABI) detailed implementation plan |
| `Phase2.md` | Phase 2 (LLVM IR integration) detailed implementation plan |

## Technical Mechanisms

### Processing Flow

```
Julia code (@cxx macro)
    ↓
Syntax parsing and type information extraction (cxxmacro.jl)
    ↓
Staged function (@generated)
    ↓
Clang AST generation (codegen.jl)
    ↓
LLVM IR generation (Clang CodeGen)
    ↓
llvmcall embedding
    ↓
Julia runtime execution
```

### Important Concepts

1. **llvmcall**: Feature to directly embed LLVM IR into Julia code
2. **Staged functions (@generated)**: Generate code at compile time based on type information
3. **Clang integration**: C++ code parsing and AST generation
4. **Type conversion**: Bidirectional conversion between Julia types and C++ types

## Development Guidelines

### Code Style

- Follow Julia coding conventions
- Function names in snake_case (e.g., `build_cpp_call`)
- Type names in PascalCase (e.g., `CppValue`)
- Comments written in English (matching existing style)

### Testing

```bash
# Run tests
julia --project -e 'using Pkg; Pkg.test()'
```

### Building

```bash
# Build
julia --project -e 'using Pkg; Pkg.build()'
```

## LastCall.jl Plan

Planning a Rust implementation version (LastCall.jl) based on Cxx.jl:

### Phase 1: C-Compatible ABI (2-3 months)
- `@rust` macro: `ccall` wrapper
- Basic type mapping
- `rust""` string literal

### Phase 2: LLVM IR Integration (4-6 months)
- Compile Rust code to LLVM IR
- Embed into `llvmcall`
- Ownership type support

### Phase 3: rustc Internal API (Experimental)
- Use rustc's internal API
- Full type system support

## Frequently Asked Questions

### Q: Why doesn't Cxx.jl work with the latest Julia?

A: Cxx.jl is internally tightly integrated with Clang's API and requires compatibility with Julia's LLVM version. In newer Julia versions, the LLVM version has changed and support hasn't caught up.

### Q: What's the difference between Phase 1 and Phase 2 of LastCall.jl?

A: Phase 1 uses C-compatible ABI (`extern "C"`), which is simple but cannot use advanced Rust features. Phase 2 directly manipulates LLVM IR, enabling more flexible integration but with more complex implementation.

### Q: What's the difference between the two forms of llvmcall?

A: The string form passes LLVM IR as a string, and Julia wraps it. The pointer form passes a pointer to an existing LLVM function and skips wrapping. Cxx.jl uses the pointer form.

## Related Resources

- [Cxx.jl GitHub](https://github.com/JuliaInterop/Cxx.jl)
- [CxxWrap.jl](https://github.com/JuliaInterop/CxxWrap.jl) (for newer Julia versions)
- [Julia Manual: llvmcall](https://docs.julialang.org/en/v1/manual/performance-tips/#man-llvm-call)
- [LLVM Language Reference](https://llvm.org/docs/LangRef.html)

## Notes

- This project is for learning and research purposes
- For production environments, CxxWrap.jl is recommended
- LastCall.jl is in the planning stage and has not yet been implemented
