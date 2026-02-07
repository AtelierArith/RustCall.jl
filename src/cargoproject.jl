# Cargo project generation for external dependencies
# Phase 3: Auto-generate Cargo projects for rust"" with dependencies

using RustToolChain: cargo

"""
    CargoProject

Represents a temporary Cargo project for building Rust code with dependencies.

# Fields
- `name::String`: Project/crate name
- `version::String`: Project version (default "0.1.0")
- `dependencies::Vector{DependencySpec}`: List of dependencies
- `edition::String`: Rust edition (default "2021")
- `path::String`: Path to the project directory
"""
struct CargoProject
    name::String
    version::String
    dependencies::Vector{DependencySpec}
    edition::String
    path::String
end

"""
    create_cargo_project(name::String, dependencies::Vector{DependencySpec}; kwargs...) -> CargoProject

Create a temporary Cargo project with the specified dependencies.

# Arguments
- `name::String`: Project name (used as crate name)
- `dependencies::Vector{DependencySpec}`: List of dependencies

# Keyword Arguments
- `edition::String`: Rust edition (default: "2021")
- `path::Union{String, Nothing}`: Project path (default: auto-generated temp directory)

# Returns
- `CargoProject`: The created project

# Example
```julia
deps = [DependencySpec("ndarray", version="0.15")]
project = create_cargo_project("my_project", deps)
```
"""
function create_cargo_project(
    name::String,
    dependencies::Vector{DependencySpec};
    edition::String = "2021",
    path::Union{String, Nothing} = nothing
)
    # Create project directory
    if isnothing(path)
        path = mktempdir(prefix="rustcall_cargo_")
    else
        mkpath(path)
    end

    # Create Cargo.toml
    cargo_toml_content = generate_cargo_toml(name, dependencies, edition)
    write(joinpath(path, "Cargo.toml"), cargo_toml_content)

    # Create src directory and empty lib.rs
    src_dir = joinpath(path, "src")
    mkpath(src_dir)
    lib_rs_path = joinpath(src_dir, "lib.rs")
    touch(lib_rs_path)

    CargoProject(name, "0.1.0", dependencies, edition, path)
end

"""
    generate_cargo_toml(name::String, deps::Vector{DependencySpec}, edition::String) -> String

Generate Cargo.toml content for a project.

# Arguments
- `name::String`: Project name
- `deps::Vector{DependencySpec}`: Dependencies
- `edition::String`: Rust edition

# Returns
- `String`: Cargo.toml content
"""
function generate_cargo_toml(name::String, deps::Vector{DependencySpec}, edition::String)
    lines = String[]

    # Package section
    push!(lines, "[package]")
    push!(lines, "name = \"$name\"")
    push!(lines, "version = \"0.1.0\"")
    push!(lines, "edition = \"$edition\"")
    push!(lines, "")

    # Library section - build as cdylib for FFI
    push!(lines, "[lib]")
    push!(lines, "crate-type = [\"cdylib\"]")
    push!(lines, "")

    # Dependencies section
    push!(lines, "[dependencies]")
    for dep in deps
        dep_line = format_dependency_line(dep)
        push!(lines, dep_line)
    end

    # Profile for release builds (faster FFI)
    push!(lines, "")
    push!(lines, "[profile.release]")
    push!(lines, "opt-level = 3")
    push!(lines, "lto = true")

    join(lines, "\n")
end

"""
    format_dependency_line(dep::DependencySpec) -> String

Format a single dependency for Cargo.toml.

# Examples
```julia
format_dependency_line(DependencySpec("ndarray", version="0.15"))
# => "ndarray = \"0.15\""

format_dependency_line(DependencySpec("serde", version="1.0", features=["derive"]))
# => "serde = { version = \"1.0\", features = [\"derive\"] }"
```
"""
function format_dependency_line(dep::DependencySpec)
    name = dep.name

    # Git dependency
    if !isnothing(dep.git)
        if !isempty(dep.features)
            features_str = join(["\"$f\"" for f in dep.features], ", ")
            return "$name = { git = \"$(dep.git)\", features = [$features_str] }"
        else
            return "$name = { git = \"$(dep.git)\" }"
        end
    end

    # Path dependency
    if !isnothing(dep.path)
        if !isempty(dep.features)
            features_str = join(["\"$f\"" for f in dep.features], ", ")
            return "$name = { path = \"$(dep.path)\", features = [$features_str] }"
        else
            return "$name = { path = \"$(dep.path)\" }"
        end
    end

    # Version dependency with features
    if !isempty(dep.features)
        features_str = join(["\"$f\"" for f in dep.features], ", ")
        return "$name = { version = \"$(dep.version)\", features = [$features_str] }"
    end

    # Simple version dependency
    if !isnothing(dep.version)
        return "$name = \"$(dep.version)\""
    end

    # No version specified (use latest)
    return "$name = \"*\""
end

"""
    write_rust_code_to_project(project::CargoProject, code::String)

Write Rust code to the project's src/lib.rs, removing dependency comments.

# Arguments
- `project::CargoProject`: The Cargo project
- `code::String`: Rust source code (may contain dependency comments)
"""
function write_rust_code_to_project(project::CargoProject, code::String)
    # Remove dependency comments from the code
    clean_code = remove_dependency_comments(code)

    # Write to lib.rs
    lib_rs_path = joinpath(project.path, "src", "lib.rs")
    write(lib_rs_path, clean_code)
end

"""
    remove_dependency_comments(code::String) -> String

Remove dependency specification comments from Rust code.

Removes:
1. `//! ```cargo ... ``` ` blocks
2. `// cargo-deps: ...` lines

# Arguments
- `code::String`: Original Rust code

# Returns
- `String`: Code without dependency comments
"""
function remove_dependency_comments(code::String)
    # Remove //! ```cargo ... ``` blocks
    # This needs to handle multi-line blocks
    lines = split(code, '\n')
    result_lines = String[]
    in_cargo_block = false

    for line in lines
        stripped = strip(line)

        if startswith(stripped, "//!")
            content = strip(stripped[4:end])

            if content == "```cargo" || startswith(content, "```cargo")
                in_cargo_block = true
                continue
            elseif in_cargo_block && content == "```"
                in_cargo_block = false
                continue
            elseif in_cargo_block
                continue
            end
        end

        if !in_cargo_block
            push!(result_lines, line)
        end
    end

    code = join(result_lines, '\n')

    # Remove // cargo-deps: ... lines
    code = replace(code, r"//\s*cargo-deps:.*?(?:\n|$)" => "")

    # Clean up multiple consecutive blank lines
    code = replace(code, r"\n{3,}" => "\n\n")

    strip(code)
end

"""
    cleanup_cargo_project(project::CargoProject)

Remove the temporary Cargo project directory.

# Arguments
- `project::CargoProject`: The project to clean up
"""
function cleanup_cargo_project(project::CargoProject)
    if isdir(project.path)
        rm(project.path, recursive=true, force=true)
    end
end

"""
    get_project_lib_name(project::CargoProject) -> String

Get the library file name for the project (platform-specific).

# Returns
- Library filename (e.g., "libmy_project.dylib" on macOS)
"""
function get_project_lib_name(project::CargoProject)
    lib_ext = get_library_extension()
    # Cargo uses underscores in library names (converts hyphens)
    crate_name = replace(project.name, "-" => "_")
    "lib$(crate_name)$(lib_ext)"
end
