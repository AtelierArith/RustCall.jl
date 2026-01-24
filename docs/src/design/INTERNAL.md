# Cxx.jl Internal Implementation Details

This document explains in detail how C++ code is processed and integrated with Julia.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Processing Flow](#processing-flow)
3. [Macro Processing (`@cxx`)](#macro-processing-cxx)
4. [String Literals (`cxx""` and `icxx""`)](#string-literals-cxx-and-icxx)
5. [Type System](#type-system)
6. [Code Generation Process](#code-generation-process)
7. [Clang Integration](#clang-integration)
8. [LLVM IR Integration](#llvm-ir-integration)

---

## Architecture Overview

Cxx.jl consists of three main components:

1. **Julia-side macros and staged functions**: Parse Julia syntax and extract type information
2. **Clang integration**: Parse C++ code and generate AST (Abstract Syntax Tree)
3. **LLVM integration**: Generate LLVM IR from Clang AST and embed it into Julia's `llvmcall`

### Data Flow

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

---

## Processing Flow

### 1. Macro Expansion Stage

When a user writes `@cxx foo::bar(args...)`:

```julia
# cxxmacro.jl's cpps_impl function processes it
@cxx foo::bar(args...)
    ↓
# Parse syntax and extract namespace and function name
Stored as CppNNS{(:foo, :bar)} in type parameters
    ↓
# Generate expression calling staged function cppcall
cppcall(__current_compiler__, CppNNS{(:foo, :bar)}(), args...)
```

### 2. Staged Function Execution Stage

`@generated` functions execute at compile time and generate code based on type information:

```julia
@generated function cppcall(CT::CxxInstance, expr, args...)
    # CT: Compiler instance
    # expr: CppNNS{(:foo, :bar)} type
    # args: Argument type information

    C = instance(CT)  # Get Clang instance

    # 1. Type checking
    check_args(argt, expr)

    # 2. Build Clang AST
    callargs, pvds = buildargexprs(C, argt)
    d = declfornns(C, expr)  # Name resolution

    # 3. Generate call expression
    ce = CreateCallExpr(C, dne, callargs)

    # 4. Generate LLVM IR and embed into llvmcall
    EmitExpr(C, ce, ...)
end
```

### 3. Clang AST Generation

The `buildargexprs` function converts Julia arguments to Clang AST nodes:

```julia
function buildargexprs(C, argt; derefval = true)
    callargs = pcpp"clang::Expr"[]
    pvds = pcpp"clang::ParmVarDecl"[]

    for i in 1:length(argt)
        t = argt[i]
        st = stripmodifier(t)  # Remove modifiers

        # Get Clang type
        argit = cpptype(C, st)

        # Create ParmVarDecl (function parameter declaration)
        argpvd = CreateParmVarDecl(C, argit)
        push!(pvds, argpvd)

        # Create DeclRefExpr (variable reference)
        expr = CreateDeclRefExpr(C, argpvd)

        # Apply modifiers (*, &, etc.)
        expr = resolvemodifier(C, t, expr)
        push!(callargs, expr)
    end

    callargs, pvds
end
```

### 4. LLVM IR Generation and Embedding

The `EmitExpr` function generates LLVM IR from Clang AST and embeds it into Julia's `llvmcall`:

```julia
function EmitExpr(C, ce, nE, ctce, argt, pvds, rett = Cvoid)
    # 1. Create LLVM function
    f = CreateFunctionWithPersonality(C, llvmrt, map(julia_to_llvm, llvmargt))

    # 2. Setup Clang code generation environment
    state = setup_cpp_env(C, f)
    builder = irbuilder(C)

    # 3. Process LLVM arguments
    args = llvmargs(C, builder, f, llvmargt)

    # 4. Associate Clang AST with LLVM values
    associateargs(C, builder, argt, args, pvds)

    # 5. Compile Clang AST to LLVM IR
    ret = EmitCallExpr(C, ce, rslot)

    # 6. Generate llvmcall expression
    createReturn(C, builder, f, argt, llvmargt, llvmrt, rett, rt, ret, state)
end
```

Finally, an `llvmcall` expression like the following is generated:

```julia
Expr(:call, Core.Intrinsics.llvmcall,
    convert(Ptr{Cvoid}, f),  # Pointer to LLVM function
    rett,                    # Return type
    Tuple{argt...},         # Argument types
    args2...)               # Actual arguments
```

---

## Macro Processing (`@cxx`)

### Syntax Parsing

The `cpps_impl` function in `cxxmacro.jl` parses Julia syntax and extracts C++ intent:

```julia
# Example: @cxx foo::bar::baz(a, b)
#
# 1. Extract namespace
nns = Expr(:curly, Tuple, :foo, :bar, :baz)

# 2. Detect function call
cexpr = :(baz(a, b))

# 3. Generate staged function call
build_cpp_call(mod, cexpr, nothing, nns)
    ↓
cppcall(__current_compiler__, CppNNS{(:foo, :bar, :baz)}(), a, b)
```

### Member Calls

For `@cxx obj->method(args)`:

```julia
# 1. Detect -> operator
expr.head == :(->)
a = expr.args[1]  # obj
b = expr.args[2]  # method(args)

# 2. Call staged function for member call
cppcall_member(__current_compiler__, CppNNS{(:method,)}(), obj, args...)
```

### Modifier Processing

- `@cxx foo(*(a))`: Wrapped with `CppDeref`
- `@cxx foo(&a)`: Wrapped with `CppAddr`
- `@cxx foo(cast(T, a))`: Wrapped with `CppCast`

---

## String Literals (`cxx""` and `icxx""`)

### `cxx""` (Global Scope)

Processed by `process_cxx_string` function in `cxxstr.jl`:

```julia
cxx"""
    void myfunction(int x) {
        std::cout << x << std::endl;
    }
"""
```

Processing flow:

1. **Extract Julia expressions**: Detect Julia expressions embedded with `$`
2. **Replace placeholders**: Replace with `__julia::var1`, `__julia::var2`, etc.
3. **Pass to Clang parser**: `EnterBuffer` or `EnterVirtualSource`
4. **Parse**: Parse C++ code with `ParseToEndOfFile`
5. **Execute global constructors**: `RunGlobalConstructors`

### `icxx""` (Function Scope)

`icxx""` is used within functions and evaluated at runtime:

```julia
function myfunc(x)
    icxx"""
        int result = $(x) * 2;
        return result;
    """
end
```

Processing flow:

1. **Generate staged function**: `cxxstr_impl` executes as `@generated` function
2. **Create Clang function**: Create Clang function declaration with `CreateFunctionWithBody`
3. **Parse**: Parse function body with `ParseFunctionStatementBody`
4. **Generate LLVM IR**: Compile to LLVM IR with `EmitTopLevelDecl`
5. **Generate call expression**: Generate expression to call function with `CallDNE`

### Julia Expression Embedding

When embedding Julia expressions with `$` syntax:

```julia
cxx"""
    void test() {
        $:(println("Hello from Julia")::Nothing);
    }
"""
```

Processing:

1. `find_expr` function detects `$`
2. Parse Julia expression: `Meta.parse(str, idx + 1)`
3. Replace with placeholder: `__juliavar1`, etc.
4. Clang's external semantic source evaluates Julia expression at runtime

---

## Type System

### Conversion from Julia Types to C++ Types

The `cpptype` function in `typetranslation.jl` handles conversion:

```julia
# Basic types
cpptype(C, ::Type{Int32}) → QualType (pointer to clang::Type*)

# C++ classes
cpptype(C, ::Type{CppBaseType{:MyClass}})
    → lookup_ctx(C, :MyClass)  # Name resolution
    → typeForDecl(decl)        # Get Clang type

# Templates
cpptype(C, ::Type{CppTemplate{CppBaseType{:vector}, Tuple{Int32}}})
    → specialize_template(C, cxxt, targs)  # Template specialization
    → typeForDecl(specialized_decl)

# Pointers and references
cpptype(C, ::Type{CppPtr{T, CVR}})
    → pointerTo(C, cpptype(C, T))  # Get pointer type
    → addQualifiers(..., CVR)      # Add const/volatile/restrict
```

### Conversion from C++ Types to Julia Types

The `juliatype` function handles conversion:

```julia
function juliatype(t::QualType, quoted = false, typeargs = Dict{Int,Cvoid}())
    CVR = extractCVR(t)  # Extract const/volatile/restrict
    t = extractTypePtr(t)
    t = canonicalType(t)  # Normalize

    if isPointerType(t)
        pt = getPointeeType(t)
        tt = juliatype(pt, quoted, typeargs)
        return CppPtr{tt, CVR}
    elseif isReferenceType(t)
        t = getPointeeType(t)
        pointeeT = juliatype(t, quoted, typeargs)
        return CppRef{pointeeT, CVR}
    elseif isEnumeralType(t)
        T = juliatype(getUnderlyingTypeOfEnum(t))
        return CppEnum{Symbol(get_name(t)), T}
    # ... other types
end
```

### Type Representation

- **CppBaseType{s}**: Base types (e.g., `int`, `MyClass`)
- **CppTemplate{T, targs}**: Template types (e.g., `std::vector<int>`)
- **CppPtr{T, CVR}**: Pointer types
- **CppRef{T, CVR}**: Reference types
- **CppValue{T, N}**: Value types (on stack)
- **CxxQualType{T, CVR}**: Types with CVR qualifiers

---

## Code Generation Process

### 1. Argument Preparation (`buildargexprs`)

```julia
function buildargexprs(C, argt; derefval = true)
    # For each argument:
    # 1. Get Clang type
    argit = cpptype(C, stripmodifier(t))

    # 2. Create ParmVarDecl (function parameter declaration)
    argpvd = CreateParmVarDecl(C, argit)

    # 3. Create DeclRefExpr (variable reference expression)
    expr = CreateDeclRefExpr(C, argpvd)

    # 4. Apply modifiers (*, &, etc.)
    expr = resolvemodifier(C, t, expr)
end
```

### 2. Name Resolution (`declfornns`)

```julia
function declfornns(C, ::Type{CppNNS{Tnns}}, cxxscope=C_NULL)
    nns = Tnns.parameters  # (:foo, :bar, :baz)
    d = translation_unit(C)  # Start from translation unit

    for (i, n) in enumerate(nns)
        if n <: CppTemplate
            # Template specialization
            d = specialize_template_clang(C, cxxt, arr)
        else
            # Normal name resolution
            d = lookup_name(C, (n,), cxxscope, d, i != length(nns))
        end
    end

    d
end
```

### 3. Call Expression Generation

```julia
# Normal function call
ce = CreateCallExpr(C, dne, callargs)

# Member function call
me = BuildMemberReference(C, callargs[1], cpptype(C, argt[1]),
                          argt[1] <: CppPtr, fname)
ce = BuildCallToMemberFunction(C, me, callargs[2:end])

# Constructor call
ctce = BuildCXXTypeConstructExpr(C, rt, callargs)

# new expression
nE = BuildCXXNewExpr(C, QualType(typeForDecl(cxxd)), callargs)
```

### 4. LLVM IR Generation

```julia
function EmitExpr(C, ce, nE, ctce, argt, pvds, rett = Cvoid)
    # 1. Create LLVM function
    f = CreateFunctionWithPersonality(C, llvmrt, map(julia_to_llvm, llvmargt))

    # 2. Setup code generation environment
    state = setup_cpp_env(C, f)
    builder = irbuilder(C)

    # 3. Process LLVM arguments (convert from Julia types to LLVM types)
    args = llvmargs(C, builder, f, llvmargt)

    # 4. Associate Clang AST with LLVM values
    associateargs(C, builder, argt, args, pvds)

    # 5. Compile Clang AST to LLVM IR
    if ce != C_NULL
        ret = EmitCallExpr(C, ce, rslot)
    elseif nE != C_NULL
        ret = EmitCXXNewExpr(C, nE)
    elseif ctce != C_NULL
        EmitAnyExprToMem(C, ctce, args[1], true)
    end

    # 6. Generate llvmcall expression
    createReturn(C, builder, f, argt, llvmargt, llvmrt, rett, rt, ret, state)
end
```

### 5. LLVM Value Conversion

The `resolvemodifier_llvm` function converts Julia's LLVM representation to Clang's LLVM representation:

```julia
# Pointer type
resolvemodifier_llvm(C, builder, t::Type{Ptr{ptr}}, v)
    → IntToPtr(builder, v, toLLVM(C, cpptype(C, Ptr{ptr})))

# CppValue type (value type)
resolvemodifier_llvm(C, builder, t::Type{T} where T <: CppValue, v)
    → CreatePointerFromObjref(C, builder, v)
    → CreateBitCast(builder, v, getPointerTo(getPointerTo(toLLVM(C, ty))))

# CppRef type (reference)
resolvemodifier_llvm(C, builder, t::Type{CppRef{T, CVR}}, v)
    → IntToPtr(builder, v, toLLVM(C, ty))
```

---

## Clang Integration

### Clang Instance Initialization

`setup_instance` function in `initialization.jl`:

```julia
function setup_instance(PCHBuffer = []; makeCCompiler=false, ...)
    x = Ref{ClangCompiler}()

    # Call C++ side init_clang_instance
    ccall((:init_clang_instance, libcxxffi), Cvoid,
        (Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}, ...),
        x, target, CPU, sysroot, ...)

    # Apply default ABI
    useDefaultCxxABI && ccall((:apply_default_abi, libcxxffi), ...)

    x[]
end
```

### Adding Header Search Paths

```julia
function addHeaderDir(C, dirname; kind = C_User, isFramework = false)
    ccall((:add_directory, libcxxffi), Cvoid,
        (Ref{ClangCompiler}, Cint, Cint, Ptr{UInt8}),
        C, kind, isFramework, dirname)
end
```

### Source Buffer Input

```julia
# Anonymous buffer
function EnterBuffer(C, buf)
    ccall((:EnterSourceFile, libcxxffi), Cvoid,
        (Ref{ClangCompiler}, Ptr{UInt8}, Csize_t),
        C, buf, sizeof(buf))
end

# Virtual file (specify filename)
function EnterVirtualSource(C, buf, file::String)
    ccall((:EnterVirtualFile, libcxxffi), Cvoid,
        (Ref{ClangCompiler}, Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
        C, buf, sizeof(buf), file, sizeof(file))
end
```

### Parsing

```julia
function ParseToEndOfFile(C)
    hadError = ccall((:_cxxparse, libcxxffi), Cint, (Ref{ClangCompiler},), C) == 0
    if !hadError
        RunGlobalConstructors(C)  # Execute global constructors
    end
    !hadError
end
```

---

## LLVM IR Integration

### Using llvmcall

Cxx.jl uses Julia's `llvmcall` in the second form (pointer form):

```julia
llvmcall(convert(Ptr{Cvoid}, f),  # Pointer to LLVM function
         rett,                     # Return type
         Tuple{argt...},          # Argument type tuple
         args...)                 # Actual arguments
```

In this form, Julia directly calls the LLVM function and performs argument conversion and inlining.

### LLVM Function Creation

```julia
function CreateFunction(C, rt, argt)
    pcpp"llvm::Function"(
        ccall((:CreateFunction, libcxxffi), Ptr{Cvoid},
            (Ref{ClangCompiler}, Ptr{Cvoid}, Ptr{Ptr{Cvoid}}, Csize_t),
            C, rt, cptrarr(argt), length(argt)))
end
```

### Type Conversion

```julia
function julia_to_llvm(@nospecialize x)
    isboxed, ty = _julia_to_llvm(x)
    isboxed ? getPRJLValueTy() : ty  # Boxed types become jl_value_t*
end
```

### Return Value Processing

The `createReturn` function converts LLVM IR return values to Julia format:

```julia
function createReturn(C, builder, f, argt, llvmargt, llvmrt, rett, rt, ret, state)
    if ret == C_NULL
        CreateRetVoid(builder)
    else
        if rett <: CppEnum || rett <: CppFptr
            # Wrap in struct
            undef = getUndefValue(llvmrt)
            ret = InsertValue(builder, undef, ret, 0)
        elseif rett <: CppRef || rett <: CppPtr || rett <: Ptr
            # Convert pointer to integer
            ret = PtrToInt(builder, ret, llvmrt)
        elseif rett <: CppValue
            # Value types need special processing
            # ...
        end
        CreateRet(builder, ret)
    end

    # Generate llvmcall expression
    Expr(:call, Core.Intrinsics.llvmcall, convert(Ptr{Cvoid}, f), rett, ...)
end
```

---

## Memory Management

### C++ Object Lifecycle

- **CppPtr**: Pointer to heap-allocated object
- **CppRef**: Reference to existing object
- **CppValue**: Value stored on stack or within Julia struct

### Destructor Invocation

For types with non-trivial destructors in `CppValue`:

```julia
if rett <: CppValue
    T = cpptype(C, rett)
    D = getAsCXXRecordDecl(T)
    if D != C_NULL && !hasTrivialDestructor(C, D)
        # Register finalizer to call destructor
        push!(B.args, :(finalizer($(get_destruct_for_instance(C)), r)))
    end
end
```

---

## Error Handling

### C++ Exception Processing

C++ exceptions are converted to Julia exceptions in `exceptions.jl`:

```julia
function setup_exception_callback()
    callback = cglobal((:process_cxx_exception, libcxxffi), Ptr{Cvoid})
    unsafe_store!(callback, @cfunction(process_cxx_exception, Union{}, (UInt64, Ptr{Cvoid})))
end
```

When an exception occurs on the C++ side, this callback is invoked and converted to a Julia exception.

---

## Optimization Points

1. **Type information utilization**: Staged functions allow appropriate C++ functions to be selected at compile time since types are determined
2. **Inlining**: `llvmcall` allows LLVM IR to be inlined into Julia's IR, applying optimizations
3. **PCH (Precompiled Header)**: Precompile frequently used headers for speed
4. **Template specialization cache**: Reuse once-specialized templates

---

## Summary

Cxx.jl achieves C++ and Julia interop by combining the following technologies:

1. **Macros and staged functions**: Syntax parsing and type information extraction
2. **Clang integration**: C++ code parsing and AST generation
3. **LLVM integration**: Conversion from AST to LLVM IR and embedding into Julia
4. **Type system**: Bidirectional conversion between Julia types and C++ types

This architecture enables direct calls to C++ code from Julia and leverages optimizations from both languages.
