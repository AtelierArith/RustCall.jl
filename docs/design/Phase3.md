# Phase 3: External Library Integration and rustscript-style Format

## Overview

In Phase 3, we enable the use of external Rust crates (libraries) within `rust""` string literals and support rustscript-style dependency specification formats. This allows practical code using external libraries like ndarray to be executed directly from Julia.

**Target Duration**: 3-4 months
**Deliverable**: External crate dependency management, rustscript-style format, automatic Cargo project generation, ndarray integration example

---

## Implementation Task List

### Task 1: Dependency Parser Implementation

**Priority**: Highest
**Estimate**: 1 week

#### Implementation Details

1. **rustscript-style Format Parsing**

   ```julia
   # src/dependencies.jl

   """
   Parse rustscript-style dependency specifications

   Supported formats:
   1. Documentation comment format:
      //! ```cargo
      //! [dependencies]
      //! ndarray = "0.15"
      //! serde = { version = "1.0", features = ["derive"] }
      //! ```

   2. Single-line comment format:
      // cargo-deps: ndarray="0.15", serde="1.0"
   """
   struct DependencySpec
       name::String
       version::Union{String, Nothing}
       features::Vector{String}
       git::Union{String, Nothing}
       path::Union{String, Nothing}
   end

   function parse_dependencies_from_code(code::String)
       deps = DependencySpec[]

       # Format 1: Parse documentation comment format
       cargo_block = extract_cargo_block(code)
       if !isnothing(cargo_block)
           deps = vcat(deps, parse_cargo_toml_block(cargo_block))
       end

       # Format 2: Parse single-line comment format
       cargo_deps_line = extract_cargo_deps_line(code)
       if !isnothing(cargo_deps_line)
           deps = vcat(deps, parse_cargo_deps_line(cargo_deps_line))
       end

       deps
   end

   function extract_cargo_block(code::String)
       # Extract ```cargo ... ``` block
       pattern = r"```cargo\n(.*?)```"s
       m = match(pattern, code)
       isnothing(m) ? nothing : m.captures[1]
   end

   function parse_cargo_toml_block(block::String)
       # Parse TOML-format dependencies
       # Extract and parse [dependencies] section
       deps = DependencySpec[]
       # Implementation: Parse with TOML parser or regex
       deps
   end

   function extract_cargo_deps_line(code::String)
       # Extract // cargo-deps: ... line
       pattern = r"//\s*cargo-deps:\s*(.+?)(?:\n|$)"
       m = match(pattern, code)
       isnothing(m) ? nothing : m.captures[1]
   end

   function parse_cargo_deps_line(line::String)
       # Parse cargo-deps: name="version", name2="version2"
       deps = DependencySpec[]
       # Implementation: Split by comma and parse
       deps
   end
   ```

2. **Dependency Normalization**

   ```julia
   function normalize_dependency(dep::DependencySpec)
       # Normalize version specification
       # Sort features
       # Check for duplicates
       dep
   end

   function merge_dependencies(deps1::Vector{DependencySpec}, deps2::Vector{DependencySpec})
       # Merge dependencies (remove duplicates)
       merged = Dict{String, DependencySpec}()
       for dep in vcat(deps1, deps2)
           if haskey(merged, dep.name)
               # Resolve version conflicts
               merged[dep.name] = resolve_version_conflict(merged[dep.name], dep)
           else
               merged[dep.name] = dep
           end
       end
       collect(values(merged))
   end
   ```

---

### Task 2: Automatic Cargo Project Generation

**Priority**: Highest
**Estimate**: 1 week

#### Implementation Details

1. **Cargo.toml Generation**

   ```julia
   # src/cargoproject.jl

   struct CargoProject
       name::String
       version::String
       dependencies::Vector{DependencySpec}
       edition::String
       path::String
   end

   function create_cargo_project(
       name::String,
       dependencies::Vector{DependencySpec};
       edition::String = "2021",
       path::Union{String, Nothing} = nothing
   )
       if isnothing(path)
           path = mktempdir(prefix="lastcall_cargo_")
       end

       # Generate Cargo.toml
       cargo_toml = generate_cargo_toml(name, dependencies, edition)
       write(joinpath(path, "Cargo.toml"), cargo_toml)

       # Create src/main.rs (or lib.rs)
       src_dir = joinpath(path, "src")
       mkpath(src_dir)
       lib_rs_path = joinpath(src_dir, "lib.rs")
       # lib.rs will be written with Rust code later

       CargoProject(name, "0.1.0", dependencies, edition, path)
   end

   function generate_cargo_toml(name::String, deps::Vector{DependencySpec}, edition::String)
       lines = String[]
       push!(lines, "[package]")
       push!(lines, "name = \"$name\"")
       push!(lines, "version = \"0.1.0\"")
       push!(lines, "edition = \"$edition\"")
       push!(lines, "")
       push!(lines, "[lib]")
       push!(lines, "crate-type = [\"cdylib\"]")
       push!(lines, "")
       push!(lines, "[dependencies]")

       for dep in deps
           dep_line = format_dependency_line(dep)
           push!(lines, dep_line)
       end

       join(lines, "\n")
   end

   function format_dependency_line(dep::DependencySpec)
       if !isnothing(dep.git)
           return "$(dep.name) = { git = \"$(dep.git)\" }"
       elseif !isnothing(dep.path)
           return "$(dep.name) = { path = \"$(dep.path)\" }"
       elseif !isempty(dep.features)
           features_str = join(dep.features, ", ")
           return "$(dep.name) = { version = \"$(dep.version)\", features = [$features_str] }"
       else
           return "$(dep.name) = \"$(dep.version)\""
       end
   end
   ```

2. **Rust Code Integration**

   ```julia
   function write_rust_code_to_project(project::CargoProject, code::String)
       # Remove dependency comments
       clean_code = remove_dependency_comments(code)

       # Write to lib.rs
       lib_rs_path = joinpath(project.path, "src", "lib.rs")
       write(lib_rs_path, clean_code)
   end

   function remove_dependency_comments(code::String)
       # Remove ```cargo ... ``` block
       code = replace(code, r"```cargo\n.*?```"s => "")

       # Remove // cargo-deps: ... line
       code = replace(code, r"//\s*cargo-deps:.*?\n" => "")

       code
   end
   ```

---

### Task 3: Cargo Build Integration

**Priority**: Highest
**Estimate**: 1 week

#### Implementation Details

1. **Cargo Build Execution**

   ```julia
   # src/cargobuild.jl

   function build_cargo_project(project::CargoProject; release::Bool = false)
       # Execute cargo build
       cmd = `cargo build $(release ? "--release" : "")`
       cd(project.path) do
           try
               run(cmd)
           catch e
               error("Cargo build failed: $e")
           end
       end

       # Get generated library path
       lib_path = get_built_library_path(project, release)
       if !isfile(lib_path)
           error("Library not found after build: $lib_path")
       end

       lib_path
   end

   function get_built_library_path(project::CargoProject, release::Bool)
       target_dir = release ? "release" : "debug"
       lib_ext = @static Sys.iswindows() ? ".dll" : (@static Sys.isapple() ? ".dylib" : ".so")
       lib_name = "lib$(project.name)$lib_ext"
       joinpath(project.path, "target", target_dir, lib_name)
   end
   ```

2. **Build Cache Integration**

   ```julia
   function build_cargo_project_cached(
       project::CargoProject,
       code_hash::String;
       release::Bool = false
   )
       # Include dependency hash as well
       deps_hash = hash_dependencies(project.dependencies)
       cache_key = "$(code_hash)_$(deps_hash)_$(release)"

       # Check cache
       cached_lib = get_cached_library(cache_key)
       if !isnothing(cached_lib) && isfile(cached_lib)
           return cached_lib
       end

       # Build
       lib_path = build_cargo_project(project, release=release)

       # Save to cache
       cache_library(cache_key, lib_path)

       lib_path
   end
   ```

---

### Task 4: Extension of `rust""` String Literal

**Priority**: Highest
**Estimate**: 1 week

#### Implementation Details

1. **Automatic Dependency Detection and Processing**

   ```julia
   # src/ruststr.jl (extended)

   function process_rust_string_with_dependencies(str::String, global_scope::Bool, source)
       # 1. Parse dependencies
       dependencies = parse_dependencies_from_code(str)

       # 2. Create Cargo project if dependencies exist
       if !isempty(dependencies)
           project_name = "lastcall_$(hash(str))"
           project = create_cargo_project(project_name, dependencies)

           # 3. Write Rust code to project
           write_rust_code_to_project(project, str)

           # 4. Build with Cargo
           lib_path = build_cargo_project_cached(project, hash(str))

           # 5. Load library
           lib = Libdl.dlopen(lib_path, Libdl.RTLD_GLOBAL)
           lib_name = basename(lib_path)
           register_library(lib_name, lib)

           # 6. Cleanup temporary project (optional)
           # cleanup_cargo_project(project)
       else
           # Compile with conventional method if no dependencies
           process_rust_string(str, global_scope, source)
       end

       nothing
   end
   ```

2. **Integration with Existing process_rust_string**

   ```julia
   # Extend existing function in ruststr.jl
   function process_rust_string(str::String, global_scope::Bool, source)
       # Check dependencies
       dependencies = parse_dependencies_from_code(str)

       if !isempty(dependencies)
           return process_rust_string_with_dependencies(str, global_scope, source)
       end

       # Existing implementation (no dependencies)
       # ...
   end
   ```

---

### Task 5: Dependency Version Management and Resolution

**Priority**: High
**Estimate**: 1 week

#### Implementation Details

1. **Version Conflict Resolution**

   ```julia
   # src/dependency_resolution.jl

   function resolve_version_conflict(dep1::DependencySpec, dep2::DependencySpec)
       if dep1.name != dep2.name
           error("Cannot resolve conflict between different dependencies")
       end

       # Resolution logic when version specifications differ
       # 1. Prefer more strict version specification
       # 2. Select latest based on semantic versioning
       # 3. Warn user

       if dep1.version != dep2.version
           @warn "Version conflict for $(dep1.name): $(dep1.version) vs $(dep2.version). Using $(dep1.version)"
       end

       # Merge features
       merged_features = unique(vcat(dep1.features, dep2.features))
       DependencySpec(
           dep1.name,
           dep1.version,  # Or more strict version
           merged_features,
           dep1.git,
           dep1.path
       )
   end
   ```

2. **Dependency Validation**

   ```julia
   function validate_dependencies(deps::Vector{DependencySpec})
       for dep in deps
           if isnothing(dep.version) && isnothing(dep.git) && isnothing(dep.path)
               error("Dependency $(dep.name) must have version, git, or path specified")
           end
       end
   end
   ```

---

### Task 6: Error Handling Extension

**Priority**: Medium
**Estimate**: 3 days

#### Implementation Details

1. **Cargo Build Error Handling**

   ```julia
   # src/exceptions.jl (extended)

   struct CargoBuildError <: Exception
       message::String
       stderr::String
       project_path::String
   end

   Base.showerror(io::IO, e::CargoBuildError) = print(io,
       "CargoBuildError: $(e.message)\nProject: $(e.project_path)\n$(e.stderr)")

   function build_cargo_project_with_error_handling(project::CargoProject; release::Bool = false)
       cmd = `cargo build $(release ? "--release" : "")`
       cd(project.path) do
           result = run(pipeline(cmd, stdout=stdout, stderr=stderr), wait=false)
           if !success(result)
               stderr_output = read(pipeline(cmd, stderr=stdout), String)
               throw(CargoBuildError(
                   "Cargo build failed",
                   stderr_output,
                   project.path
               ))
           end
       end
   end
   ```

2. **Dependency Resolution Error Handling**

   ```julia
   struct DependencyResolutionError <: Exception
       dependency::String
       message::String
   end

   Base.showerror(io::IO, e::DependencyResolutionError) = print(io,
       "DependencyResolutionError: $(e.dependency) - $(e.message)")
   ```

---

### Task 7: Test Suite Extension

**Priority**: High
**Estimate**: 1 week

#### Implementation Details

1. **Dependency Parser Tests**

   ```julia
   # test/test_dependencies.jl
   @testset "Dependency parsing" begin
       code1 = """
       //! ```cargo
       //! [dependencies]
       //! serde = "1.0"
       //! ```
       """
       deps = parse_dependencies_from_code(code1)
       @test length(deps) == 1
       @test deps[1].name == "serde"
       @test deps[1].version == "1.0"

       code2 = """
       // cargo-deps: ndarray="0.15", serde={version="1.0", features=["derive"]}
       """
       deps2 = parse_dependencies_from_code(code2)
       @test length(deps2) == 2
   end
   ```

2. **Cargo Project Generation Tests**

   ```julia
   # test/test_cargo.jl
   @testset "Cargo project creation" begin
       deps = [DependencySpec("ndarray", "0.15", [], nothing, nothing)]
       project = create_cargo_project("test_project", deps)

       @test isdir(project.path)
       @test isfile(joinpath(project.path, "Cargo.toml"))

       cargo_toml = read(joinpath(project.path, "Cargo.toml"), String)
       @test occursin("ndarray = \"0.15\"", cargo_toml)
   end
   ```

3. **ndarray Integration Tests**

   ```julia
   # test/test_ndarray.jl
   @testset "ndarray integration" begin
       rust"""
       //! ```cargo
       //! [dependencies]
       //! ndarray = "0.15"
       //! ```

       use ndarray::Array2;

       #[no_mangle]
       pub extern "C" fn add_arrays(
           a_ptr: *const f64,
           b_ptr: *const f64,
           len: usize,
           result_ptr: *mut f64
       ) {
           let a = unsafe { Array2::from_shape_ptr((len, 1).f(), a_ptr) };
           let b = unsafe { Array2::from_shape_ptr((len, 1).f(), b_ptr) };
           let result = &a + &b;
           unsafe {
               std::ptr::copy_nonoverlapping(
                   result.as_ptr(),
                   result_ptr,
                   result.len()
               );
           }
       }
       """

       a = [1.0, 2.0, 3.0]
       b = [4.0, 5.0, 6.0]
       result = Vector{Float64}(undef, 3)
       @rust add_arrays(pointer(a), pointer(b), 3, pointer(result))
       @test result ≈ [5.0, 7.0, 9.0]
   end
   ```

---

## Implementation Details

### File Structure (Extended)

```
src/
├── LastCall.jl              # Main module
├── rustmacro.jl         # @rust macro
├── ruststr.jl           # rust"" and irust"" (extended)
├── rusttypes.jl         # Rust type definitions
├── typetranslation.jl   # Type conversion
├── exceptions.jl        # Error handling (extended)
├── dependencies.jl     # Dependency parser (new)
├── cargoproject.jl     # Cargo project management (new)
├── cargobuild.jl       # Cargo build integration (new)
├── dependency_resolution.jl  # Dependency resolution (new)
└── ndarray.jl          # ndarray integration (new)
```

### Main Function Signatures

```julia
# dependencies.jl
parse_dependencies_from_code(code) -> Vector{DependencySpec}
extract_cargo_block(code) -> Union{String, Nothing}
parse_cargo_toml_block(block) -> Vector{DependencySpec}
extract_cargo_deps_line(code) -> Union{String, Nothing}
parse_cargo_deps_line(line) -> Vector{DependencySpec}
normalize_dependency(dep) -> DependencySpec
merge_dependencies(deps1, deps2) -> Vector{DependencySpec}

# cargoproject.jl
create_cargo_project(name, dependencies; kwargs...) -> CargoProject
generate_cargo_toml(name, deps, edition) -> String
format_dependency_line(dep) -> String
write_rust_code_to_project(project, code) -> Nothing
remove_dependency_comments(code) -> String

# cargobuild.jl
build_cargo_project(project; release) -> String
get_built_library_path(project, release) -> String
build_cargo_project_cached(project, code_hash; release) -> String

# dependency_resolution.jl
resolve_version_conflict(dep1, dep2) -> DependencySpec
validate_dependencies(deps) -> Nothing

# ndarray.jl
RustNdArray(ptr, shape, strides) -> RustNdArray
create_rust_ndarray(arr) -> RustNdArray
to_julia_array(ndarr) -> Array
```

---

## Usage Examples

### Basic External Library Usage

```julia
using LastCall

# Example using serde
rust"""
//! ```cargo
//! [dependencies]
//! serde = { version = "1.0", features = ["derive"] }
//! serde_json = "1.0"
//! ```

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
pub struct Person {
    name: String,
    age: u32,
}

#[no_mangle]
pub extern "C" fn serialize_person(name_ptr: *const u8, name_len: usize, age: u32) -> *mut u8 {
    let name = unsafe {
        std::str::from_utf8(std::slice::from_raw_parts(name_ptr, name_len)).unwrap()
    };
    let person = Person {
        name: name.to_string(),
        age,
    };
    let json = serde_json::to_string(&person).unwrap();
    // Memory management implementation needed
    // ...
}
"""
```

### Numerical Computation with ndarray

```julia
using LastCall

rust"""
//! ```cargo
//! [dependencies]
//! ndarray = "0.15"
//! ```

use ndarray::{Array2, Axis};

#[no_mangle]
pub extern "C" fn matrix_sum_rows(
    data_ptr: *const f64,
    rows: usize,
    cols: usize,
    result_ptr: *mut f64
) {
    let arr = unsafe {
        Array2::from_shape_ptr((rows, cols).f(), data_ptr)
    };
    let sums = arr.sum_axis(Axis(0));
    unsafe {
        std::ptr::copy_nonoverlapping(
            sums.as_ptr(),
            result_ptr,
            sums.len()
        );
    }
}
"""

# Use from Julia
matrix = [1.0 2.0 3.0; 4.0 5.0 6.0]
result = Vector{Float64}(undef, 3)
@rust matrix_sum_rows(pointer(matrix), 2, 3, pointer(result))
println(result)  # => [5.0, 7.0, 9.0]
```

### Single-line Comment Format Usage

```julia
rust"""
// cargo-deps: tokio="1.0", serde="1.0"

// Asynchronous processing example (simplified)
"""
```

---

## Migration from Phase 2

Extend Phase 2 features in Phase 3:

1. **rust"" string literal**: Automatic dependency detection and Cargo project generation
2. **Compilation cache**: Cache key including dependency hash
3. **Error handling**: Detailed Cargo build error display

---

## Limitations

Phase 3 still has the following limitations:

1. **proc-macro support**: Crates using proc-macros are only partially supported
2. **Build time**: First build takes time when external dependencies exist
3. **Platform-specific dependencies**: Some crates only work on specific platforms
4. **Memory management**: Additional implementation needed for complex data structure passing

---

## Next Steps (Future Extensions)

After Phase 3 is complete, consider the following features:

1. **Dependency precompilation**: Pre-build commonly used crates
2. **Binary cache**: Share pre-built libraries
3. **More advanced type mapping**: Automatic mapping of complex Rust types
4. **Asynchronous processing integration**: Integration with async runtimes like tokio

---

## Reference Implementation

- [rust-script](https://github.com/fornwall/rust-script) - Rust script execution tool
- [cargo-script](https://github.com/DanielKeep/cargo-script) - Cargo-based script execution
- [ndarray-rs](https://github.com/rust-ndarray/ndarray) - Rust multidimensional array library
- Cargo documentation: [The Cargo Book](https://doc.rust-lang.org/cargo/)
