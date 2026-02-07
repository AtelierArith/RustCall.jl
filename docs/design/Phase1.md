# Phase 1: Basic Implementation via C-Compatible ABI (MVP)

## Overview

In Phase 1, we implement basic functionality to call Rust functions from Julia using a C-compatible ABI (Application Binary Interface). This phase focuses on basic types and function calls, without using advanced Rust features (generics, traits, ownership system, etc.).

**Target Duration**: 2-3 months
**Deliverable**: Basic `@rust` macro, type mapping, string literals, error handling

---

## Implementation Task List

### Task 1: Project Structure Setup

**Priority**: Highest
**Estimate**: 1 day

#### Implementation Details

1. **Create Project Directory**
   ```
   RustCall.jl/
   ├── Project.toml
   ├── README.md
   ├── src/
   │   ├── RustCall.jl
   │   ├── rustmacro.jl
   │   ├── ruststr.jl
   │   ├── rusttypes.jl
   │   ├── typetranslation.jl
   │   ├── exceptions.jl
   │   └── utils.jl
   ├── deps/
   │   ├── build.jl
   │   └── build_librustffi.jl
   ├── test/
   │   ├── runtests.jl
   │   ├── basic.jl
   │   ├── types.jl
   │   └── strings.jl
   └── docs/
       └── src/
           └── index.md
   ```

2. **Create Project.toml**
   ```toml
   name = "Rust"
   uuid = "..." # Generated UUID
   version = "0.1.0"

   [deps]
   Libdl = "8f399da3-3557-5675-b5ff-fb832c97cbdb"
   REPL = "3fa0cd96-eef1-5676-8a61-b3b8758bbffb"

   [extras]
   Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"

   [targets]
   test = ["Test"]
   ```

3. **Basic Module Structure**
   ```julia
   # src/RustCall.jl
   __precompile__(true)
   module Rust

   module RustCore
       # Internal implementation
   end

   # Public API
   export @rust, @rust_str, @irust_str
   # ...

   end
   ```

---

### Task 2: Basic Type System Implementation

**Priority**: Highest
**Estimate**: 1 week

#### Implementation Details

1. **Julia Representation of Rust Types**

   ```julia
   # src/rusttypes.jl

   # Basic type mapping
   const RUST_TYPE_MAP = Dict(
       :i8 => Int8,
       :i16 => Int16,
       :i32 => Int32,
       :i64 => Int64,
       :u8 => UInt8,
       :u16 => UInt16,
       :u32 => UInt32,
       :u64 => UInt64,
       :f32 => Float32,
       :f64 => Float64,
       :bool => Bool,
       :usize => UInt,  # Platform-dependent
       :isize => Int,   # Platform-dependent
   )

   # Pointer type
   struct RustPtr{T}
       ptr::Ptr{Cvoid}
   end

   # Reference type (treated as Ref on Julia side)
   struct RustRef{T}
       ptr::Ptr{Cvoid}
   end

   # Result type
   struct RustResult{T, E}
       is_ok::Bool
       value::Union{T, E}

       function RustResult{T, E}(is_ok::Bool, value) where {T, E}
           new(is_ok, value)
       end
   end

   # Option type
   struct RustOption{T}
       is_some::Bool
       value::Union{T, Nothing}

       function RustOption{T}(is_some::Bool, value) where {T}
           new(is_some, value)
       end
   end
   ```

2. **Type Conversion Functions**

   ```julia
   # src/typetranslation.jl

   """
   Convert Rust type name (Symbol) to Julia type
   """
   function rusttype_to_julia(rust_type::Symbol)
       get(RUST_TYPE_MAP, rust_type) do
           error("Unsupported Rust type: $rust_type")
       end
   end

   """
   Convert Julia type to Rust type name (String)
   """
   function juliatype_to_rust(julia_type::Type)
       for (rust_sym, julia_typ) in RUST_TYPE_MAP
           if julia_typ == julia_type
               return string(rust_sym)
           end
       end
       error("Unsupported Julia type: $julia_type")
   end

   """
   Parse Rust function signature to extract type information
   """
   function parse_rust_signature(sig::String)
       # Example: "fn add(a: i32, b: i32) -> i32"
       # Implementation: Parse with regex or parser
       # Return: (function name, array of argument types, return type)
   end
   ```

---

### Task 3: Basic Implementation of `@rust` Macro

**Priority**: Highest
**Estimate**: 1 week

#### Implementation Details

1. **Basic Macro Structure**

   ```julia
   # src/rustmacro.jl

   """
       @rust expr

   Call a Rust function from Julia using C-compatible ABI.

   Examples:
       @rust add(10, 20)
       @rust mymodule::myfunction(x, y)
   """
   macro rust(expr)
       rust_impl(__module__, expr)
   end

   function rust_impl(mod, expr)
       if isexpr(expr, :call)
           build_rust_call(mod, expr)
       elseif isexpr(expr, Symbol("::"))
           build_rust_namespace_ref(mod, expr)
       else
           error("Unsupported Rust expression: $expr")
       end
   end
   ```

2. **Function Call Construction**

   ```julia
   function build_rust_call(mod, expr)
       if !isexpr(expr, :call)
           error("Expected a function call, got: $expr")
       end

       fname = expr.args[1]
       args = expr.args[2:end]

       # Get function name
       func_name = isa(fname, Symbol) ? string(fname) : error("Function name must be a Symbol")

       # Get current library
       lib_name = get_current_lib_name()

       # Infer type information (determined at runtime)
       # Note: In Phase 1, type information may need to be explicitly specified

       # Generate ccall
       quote
           ccall((Symbol($func_name), $lib_name),
                 Any,  # Return type (to be improved later)
                 ($(map(_ -> :Any, args)...),),  # Argument types (to be improved later)
                 $(map(esc, args)...))
       end
   end
   ```

3. **Library Management**

   ```julia
   # src/utils.jl

   # Manage currently loaded Rust libraries
   const loaded_libraries = Dict{String, Ptr{Cvoid}}()
   const current_lib_name = Ref{String}("")

   function get_current_lib_name()
       if isempty(current_lib_name[])
           error("No Rust library loaded. Use rust\"\" to load a library first.")
       end
       current_lib_name[]
   end

   function set_current_lib_name(name::String)
       current_lib_name[] = name
   end

   function register_library(name::String, lib::Ptr{Cvoid})
       loaded_libraries[name] = lib
       set_current_lib_name(name)
   end
   ```

---

### Task 4: Implementation of `rust""` String Literal

**Priority**: High
**Estimate**: 1 week

#### Implementation Details

1. **Macro Implementation**

   ```julia
   # src/ruststr.jl

   """
       rust"C++ code"

   Compile and load Rust code as a shared library.
   The code will be wrapped in a C-compatible interface.

   Example:
       rust\"""
           #[no_mangle]
           pub extern "C" fn add(a: i32, b: i32) -> i32 {
               a + b
           }
       \"""
   """
   macro rust_str(str, args...)
       process_rust_string(str, true, __source__)
   end
   ```

2. **Rust Code Compilation**

   ```julia
   function process_rust_string(str::String, global_scope::Bool, source)
       # 1. Write to temporary file
       tmp_file = tempname() * ".rs"
       write(tmp_file, wrap_rust_code(str))

       # 2. Compile
       lib_path = compile_rust_file(tmp_file)

       # 3. Load shared library
       lib = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL)

       # 4. Register library
       lib_name = basename(lib_path)
       register_library(lib_name, lib)

       # 5. Register functions (optional)
       register_functions_from_lib(lib)

       nothing
   end

   function wrap_rust_code(code::String)
       # Wrap Rust code as needed
       # Example: Add extern "C" block, etc.
       code
   end

   function compile_rust_file(rs_file::String)
       lib_ext = @static Sys.iswindows() ? ".dll" : (@static Sys.isapple() ? ".dylib" : ".so")
       lib_path = rs_file * lib_ext

       # Compile with rustc
       cmd = `rustc --crate-type cdylib -o $lib_path $rs_file`
       run(cmd)

       if !isfile(lib_path)
           error("Failed to compile Rust file: $rs_file")
       end

       lib_path
   end
   ```

3. **Automatic Function Registration (Optional)**

   ```julia
   function register_functions_from_lib(lib::Ptr{Cvoid})
       # Detect exported functions from shared library
       # Note: This requires complex implementation (using tools like objdump, nm)
       # Manual registration is acceptable in Phase 1
   end
   ```

---

### Task 5: Implementation of `irust""` String Literal (Limited Version)

**Priority**: Medium
**Estimate**: 3 days

#### Implementation Details

1. **Macro Implementation**

   ```julia
   """
       irust"Rust code"

   Execute Rust code at function scope.
   Note: This is limited in Phase 1 and may require
   compilation to a separate function.

   Example:
       function myfunc(x)
           irust\"""
               let result = $(x) * 2;
               result
           \"""
       end
   """
   macro irust_str(str, args...)
       process_irust_string(str, __source__)
   end
   ```

2. **Limited Version Implementation**

   ```julia
   function process_irust_string(str::String, source)
       # In Phase 1, irust"" has the following limitations:
       # 1. Single expression only
       # 2. Return value must be basic type only
       # 3. Compiled as a function

       # Generate temporary Rust function
       func_name = "irust_func_$(hash(str))"
       rust_code = """
       #[no_mangle]
       pub extern "C" fn $func_name($(extract_args(str))) -> $(extract_return_type(str)) {
           $str
       }
       """

       # Compile and execute
       # (Implementation similar to rust"")
   end
   ```

---

### Task 6: Result Type Support

**Priority**: High
**Estimate**: 1 week

#### Implementation Details

1. **Result Type Definition (Repeated)**

   ```julia
   # src/rusttypes.jl

   struct RustResult{T, E}
       is_ok::Bool
       value::Union{T, E}
   end

   # Convenience functions
   function unwrap(result::RustResult{T, E}) where {T, E}
       if result.is_ok
           return result.value::T
       else
           error("Unwrap failed: $(result.value::E)")
       end
   end

   function unwrap_or(result::RustResult{T, E}, default::T) where {T, E}
       result.is_ok ? result.value::T : default
   end
   ```

2. **Handling Result Type on Rust Side**

   ```rust
   // Example on Rust side
   #[repr(C)]
   pub struct RustResult<T, E> {
       pub is_ok: bool,
       pub value: *mut c_void,  // Pointer to T or E
   }

   #[no_mangle]
   pub extern "C" fn divide(a: f64, b: f64) -> RustResult<f64, *const i8> {
       if b == 0.0 {
           let err_msg = CString::new("Division by zero").unwrap();
           RustResult {
               is_ok: false,
               value: err_msg.into_raw() as *mut c_void,
           }
       } else {
           RustResult {
               is_ok: true,
               value: Box::into_raw(Box::new(a / b)) as *mut c_void,
           }
       }
   }
   ```

3. **Usage on Julia Side**

   ```julia
   # Macro extension to automatically handle Result type
   function build_rust_call_with_result(mod, expr, result_type)
       # For functions returning Result type, provide option to automatically unwrap
       # Or explicitly return Result type
   end
   ```

---

### Task 7: Error Handling

**Priority**: High
**Estimate**: 3 days

#### Implementation Details

1. **Error Type Definition**

   ```julia
   # src/exceptions.jl

   struct RustError <: Exception
       message::String
       code::Int32
   end

   Base.showerror(io::IO, e::RustError) = print(io, "RustError: $(e.message) (code: $(e.code))")
   ```

2. **Result Type to Exception Conversion**

   ```julia
   function result_to_exception(result::RustResult{T, E}) where {T, E}
       if !result.is_ok
           error_msg = result.value
           throw(RustError(string(error_msg), 0))
       end
       result.value::T
   end
   ```

---

### Task 8: Test Suite Creation

**Priority**: High
**Estimate**: 1 week

#### Implementation Details

1. **Basic Tests**

   ```julia
   # test/basic.jl
   using Rust
   using Test

   @testset "Basic Rust function calls" begin
       rust"""
       #[no_mangle]
       pub extern "C" fn add(a: i32, b: i32) -> i32 {
           a + b
       }
       """

       @test @rust add(10, 20) == 30
   end
   ```

2. **Type Tests**

   ```julia
   # test/types.jl
   @testset "Type mappings" begin
       # Test mapping for each type
   end
   ```

3. **String Literal Tests**

   ```julia
   # test/strings.jl
   @testset "String literals" begin
       # Test rust"" and irust""
   end
   ```

---

## Implementation Details

### File Structure

```
src/
├── RustCall.jl              # Main module
├── rustmacro.jl         # @rust macro
├── ruststr.jl           # rust"" and irust""
├── rusttypes.jl         # Rust type definitions
├── typetranslation.jl   # Type conversion
├── exceptions.jl        # Error handling
└── utils.jl             # Utilities
```

### Main Function Signatures

```julia
# rustmacro.jl
rust_impl(mod, expr) -> Expr
build_rust_call(mod, expr) -> Expr
build_rust_namespace_ref(mod, expr) -> Expr

# ruststr.jl
process_rust_string(str, global_scope, source) -> Nothing
compile_rust_file(rs_file) -> String
wrap_rust_code(code) -> String

# typetranslation.jl
rusttype_to_julia(rust_type) -> Type
juliatype_to_rust(julia_type) -> String
parse_rust_signature(sig) -> Tuple

# utils.jl
get_current_lib_name() -> String
set_current_lib_name(name) -> Nothing
register_library(name, lib) -> Nothing
```

---

## Limitations

Phase 1 has the following limitations:

1. **Type inference limitations**: Type information may need to be explicitly specified for functions
2. **No generics support**: Rust generics cannot be used
3. **No traits support**: Rust traits cannot be used
4. **Ownership system**: Detailed ownership management is not possible (only basic pointers/references)
5. **irust"" limitations**: Execution in function scope is limited

---

## Next Steps (Transition to Phase 2)

After Phase 1 is complete, implement the following features in Phase 2:

1. LLVM IR integration
2. More advanced type system
3. Generics support
4. Ownership system integration

---

## Reference Implementation

- Refer to Cxx.jl's `cxxmacro.jl` and `cxxstr.jl`
- Refer to Julia's `ccall` documentation
- Refer to Rust FFI guide
