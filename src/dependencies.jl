# Dependency parsing for external Rust crates
# Phase 3: rustscript-style dependency specification

using TOML

"""
    DependencySpec

Represents a single Rust crate dependency specification.

# Fields
- `name::String`: Crate name
- `version::Union{String, Nothing}`: Version specification (e.g., "0.15", "1.0")
- `features::Vector{String}`: List of crate features to enable
- `git::Union{String, Nothing}`: Git repository URL (for git dependencies)
- `path::Union{String, Nothing}`: Local path (for path dependencies)
"""
struct DependencySpec
    name::String
    version::Union{String, Nothing}
    features::Vector{String}
    git::Union{String, Nothing}
    path::Union{String, Nothing}

    function DependencySpec(
        name::String,
        version::Union{String, Nothing} = nothing,
        features::Vector{String} = String[],
        git::Union{String, Nothing} = nothing,
        path::Union{String, Nothing} = nothing
    )
        new(name, version, features, git, path)
    end
end

# Constructor with keyword arguments
function DependencySpec(name::AbstractString;
    version::Union{AbstractString, Nothing} = nothing,
    features::Vector{<:AbstractString} = String[],
    git::Union{AbstractString, Nothing} = nothing,
    path::Union{AbstractString, Nothing} = nothing
)
    DependencySpec(
        String(name),
        isnothing(version) ? nothing : String(version),
        String[String(f) for f in features],
        isnothing(git) ? nothing : String(git),
        isnothing(path) ? nothing : String(path)
    )
end

"""
    parse_dependencies_from_code(code::String) -> Vector{DependencySpec}

Parse dependencies from Rust code that contains rustscript-style dependency specifications.

Supports two formats:
1. Document comment format:
   ```
   //! ```cargo
   //! [dependencies]
   //! ndarray = "0.15"
   //! serde = { version = "1.0", features = ["derive"] }
   //! ```
   ```

2. Single-line comment format:
   ```
   // cargo-deps: ndarray="0.15", serde="1.0"
   ```

# Arguments
- `code::String`: Rust source code potentially containing dependency specifications

# Returns
- `Vector{DependencySpec}`: List of parsed dependencies (empty if none found)
"""
function parse_dependencies_from_code(code::String)
    deps = DependencySpec[]

    # Format 1: Document comment format (```cargo block)
    cargo_block = extract_cargo_block(code)
    if !isnothing(cargo_block)
        block_deps = parse_cargo_toml_block(cargo_block)
        deps = vcat(deps, block_deps)
    end

    # Format 2: Single-line comment format (// cargo-deps:)
    cargo_deps_line = extract_cargo_deps_line(code)
    if !isnothing(cargo_deps_line)
        line_deps = parse_cargo_deps_line(cargo_deps_line)
        deps = vcat(deps, line_deps)
    end

    # Merge and normalize dependencies
    if length(deps) > 1
        deps = merge_dependencies(deps)
    end

    deps
end

"""
    extract_cargo_block(code::String) -> Union{String, Nothing}

Extract the cargo TOML block from Rust code.

Looks for patterns like:
```
//! ```cargo
//! [dependencies]
//! ndarray = "0.15"
//! ```
```

# Returns
- The content inside the cargo block (without //! prefixes), or `nothing` if not found
"""
function extract_cargo_block(code::String)
    # Pattern to match //! ```cargo ... //! ``` blocks
    # First, find all lines starting with //!
    lines = split(code, '\n')

    in_cargo_block = false
    cargo_lines = String[]

    for line in lines
        stripped = strip(line)

        # Check for //! pattern
        if startswith(stripped, "//!")
            content = strip(stripped[4:end])  # Remove //! prefix

            if content == "```cargo" || startswith(content, "```cargo")
                in_cargo_block = true
                continue
            elseif in_cargo_block && content == "```"
                in_cargo_block = false
                break
            elseif in_cargo_block
                push!(cargo_lines, content)
            end
        end
    end

    if isempty(cargo_lines)
        return nothing
    end

    return join(cargo_lines, '\n')
end

"""
    parse_cargo_toml_block(block::String) -> Vector{DependencySpec}

Parse a TOML-formatted cargo block to extract dependencies.

# Arguments
- `block::String`: TOML content from a cargo block

# Returns
- `Vector{DependencySpec}`: Parsed dependencies
"""
function parse_cargo_toml_block(block::String)
    deps = DependencySpec[]

    try
        parsed = TOML.parse(block)

        # Get dependencies section
        if haskey(parsed, "dependencies")
            dep_section = parsed["dependencies"]

            for (name, spec) in dep_section
                dep = parse_toml_dependency(name, spec)
                push!(deps, dep)
            end
        end
    catch e
        @warn "Failed to parse cargo TOML block: $e"
    end

    deps
end

"""
    parse_toml_dependency(name::String, spec) -> DependencySpec

Parse a single dependency from TOML format.

# Arguments
- `name::String`: Crate name
- `spec`: Version string or dict with version, features, git, path
"""
function parse_toml_dependency(name::String, spec)
    if spec isa String
        # Simple version string: ndarray = "0.15"
        return DependencySpec(name, version=spec)
    elseif spec isa Dict
        # Complex specification: { version = "1.0", features = ["derive"] }
        version = get(spec, "version", nothing)
        features = get(spec, "features", String[])
        git = get(spec, "git", nothing)
        path = get(spec, "path", nothing)

        # Convert features to Vector{String}
        if features isa Vector
            features = String[string(f) for f in features]
        else
            features = String[]
        end

        return DependencySpec(name, version=version, features=features, git=git, path=path)
    else
        @warn "Unknown dependency specification format for $name: $(typeof(spec))"
        return DependencySpec(name)
    end
end

"""
    extract_cargo_deps_line(code::String) -> Union{String, Nothing}

Extract the cargo-deps line from Rust code.

Looks for patterns like:
```
// cargo-deps: ndarray="0.15", serde="1.0"
```

# Returns
- The content after "cargo-deps:", or `nothing` if not found
"""
function extract_cargo_deps_line(code::String)
    # Pattern: // cargo-deps: ...
    pattern = r"//\s*cargo-deps:\s*(.+?)(?:\n|$)"
    m = match(pattern, code)

    if isnothing(m)
        return nothing
    end

    return strip(m.captures[1])
end

"""
    parse_cargo_deps_line(line::AbstractString) -> Vector{DependencySpec}

Parse a cargo-deps line to extract dependencies.

Format: name="version", name2={version="1.0", features=["f1"]}

# Arguments
- `line::AbstractString`: Content after "cargo-deps:"

# Returns
- `Vector{DependencySpec}`: Parsed dependencies
"""
function parse_cargo_deps_line(line::AbstractString)
    deps = DependencySpec[]

    # Split by comma (but not inside braces or quotes)
    parts = split_cargo_deps(String(line))

    for part in parts
        part = strip(part)
        if isempty(part)
            continue
        end

        dep = parse_single_cargo_dep(String(part))
        if !isnothing(dep)
            push!(deps, dep)
        end
    end

    deps
end

"""
    _count_trailing_backslashes(s::AbstractString) -> Int

Count consecutive trailing backslash characters. Used to determine whether
a quote is escaped: the quote is escaped only if preceded by an odd number
of backslashes (e.g., `\\"` is escaped, `\\\\"` is not).
"""
function _count_trailing_backslashes(s::AbstractString)
    count = 0
    for i in lastindex(s):-1:firstindex(s)
        s[i] == '\\' || break
        count += 1
    end
    return count
end

"""
    split_cargo_deps(line::String) -> Vector{String}

Split cargo-deps line by commas, respecting braces and quotes.
"""
function split_cargo_deps(line::String)
    parts = String[]
    current = ""
    depth = 0
    in_quote = false

    for char in line
        if char == '"' && iseven(_count_trailing_backslashes(current))
            in_quote = !in_quote
            current *= char
        elseif char == '{' && !in_quote
            depth += 1
            current *= char
        elseif char == '}' && !in_quote
            depth -= 1
            current *= char
        elseif char == ',' && depth == 0 && !in_quote
            push!(parts, strip(current))
            current = ""
        else
            current *= char
        end
    end

    if !isempty(strip(current))
        push!(parts, strip(current))
    end

    parts
end

"""
    parse_single_cargo_dep(part::String) -> Union{DependencySpec, Nothing}

Parse a single dependency from cargo-deps format.

Formats:
- name="version"
- name={version="1.0", features=["f1", "f2"]}
"""
function parse_single_cargo_dep(part::String)
    # Try simple format: name="version"
    simple_pattern = r"^(\w+)\s*=\s*\"([^\"]+)\"$"
    m = match(simple_pattern, part)
    if !isnothing(m)
        name = m.captures[1]
        version = m.captures[2]
        return DependencySpec(name, version=version)
    end

    # Try complex format: name={...}
    complex_pattern = r"^(\w+)\s*=\s*\{(.+)\}$"
    m = match(complex_pattern, part)
    if !isnothing(m)
        name = m.captures[1]
        spec_str = m.captures[2]

        # Parse the spec as key=value pairs
        version = nothing
        features = String[]
        git = nothing
        path = nothing

        # Extract version
        version_match = match(r"version\s*=\s*\"([^\"]+)\"", spec_str)
        if !isnothing(version_match)
            version = version_match.captures[1]
        end

        # Extract features
        features_match = match(r"features\s*=\s*\[([^\]]*)\]", spec_str)
        if !isnothing(features_match)
            features_str = features_match.captures[1]
            # Parse feature strings
            for fm in eachmatch(r"\"([^\"]+)\"", features_str)
                push!(features, fm.captures[1])
            end
        end

        # Extract git
        git_match = match(r"git\s*=\s*\"([^\"]+)\"", spec_str)
        if !isnothing(git_match)
            git = git_match.captures[1]
        end

        # Extract path
        path_match = match(r"path\s*=\s*\"([^\"]+)\"", spec_str)
        if !isnothing(path_match)
            path = path_match.captures[1]
        end

        return DependencySpec(name, version=version, features=features, git=git, path=path)
    end

    @warn "Could not parse dependency: $part"
    return nothing
end

"""
    normalize_dependency(dep::DependencySpec) -> DependencySpec

Normalize a dependency specification.
- Sorts features alphabetically
- Trims whitespace from strings
"""
function normalize_dependency(dep::DependencySpec)
    DependencySpec(
        String(strip(dep.name)),
        version=isnothing(dep.version) ? nothing : String(strip(dep.version)),
        features=sort(String[String(f) for f in dep.features]),
        git=isnothing(dep.git) ? nothing : String(strip(dep.git)),
        path=isnothing(dep.path) ? nothing : String(strip(dep.path))
    )
end

"""
    merge_dependencies(deps::Vector{DependencySpec}) -> Vector{DependencySpec}

Merge dependencies with the same name, combining features.

# Arguments
- `deps::Vector{DependencySpec}`: List of dependencies (may contain duplicates)

# Returns
- `Vector{DependencySpec}`: Merged dependencies (no duplicates)
"""
function merge_dependencies(deps::Vector{DependencySpec})
    merged = Dict{String, DependencySpec}()

    for dep in deps
        dep = normalize_dependency(dep)

        if haskey(merged, dep.name)
            # Merge with existing dependency
            existing = merged[dep.name]
            merged[dep.name] = merge_two_dependencies(existing, dep)
        else
            merged[dep.name] = dep
        end
    end

    collect(values(merged))
end

"""
    merge_two_dependencies(dep1::DependencySpec, dep2::DependencySpec) -> DependencySpec

Merge two dependencies with the same name.
"""
function merge_two_dependencies(dep1::DependencySpec, dep2::DependencySpec)
    @assert dep1.name == dep2.name "Cannot merge dependencies with different names"

    # Use the first non-nothing version, or warn if they conflict
    version = dep1.version
    if isnothing(version)
        version = dep2.version
    elseif !isnothing(dep2.version) && dep1.version != dep2.version
        @warn "Version conflict for $(dep1.name): $(dep1.version) vs $(dep2.version). Using $(dep1.version)"
    end

    # Merge features
    features = unique(vcat(dep1.features, dep2.features))
    sort!(features)

    # Use the first non-nothing git/path
    git = isnothing(dep1.git) ? dep2.git : dep1.git
    path = isnothing(dep1.path) ? dep2.path : dep1.path

    DependencySpec(dep1.name, version=version, features=features, git=git, path=path)
end

"""
    has_dependencies(code::String) -> Bool

Check if code contains any dependency specifications.
"""
function has_dependencies(code::String)
    !isnothing(extract_cargo_block(code)) || !isnothing(extract_cargo_deps_line(code))
end
