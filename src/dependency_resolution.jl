# Dependency resolution and validation
# Phase 3: Handle version conflicts and validate dependencies

"""
    resolve_version_conflict(dep1::DependencySpec, dep2::DependencySpec) -> DependencySpec

Resolve version conflicts between two dependency specifications.

When two dependencies with the same name have different versions:
1. If one has a stricter (more specific) version, prefer that
2. Otherwise, prefer the first one and emit a warning

# Arguments
- `dep1::DependencySpec`: First dependency
- `dep2::DependencySpec`: Second dependency (same name)

# Returns
- `DependencySpec`: Resolved dependency

# Throws
- `DependencyResolutionError` if dependencies have incompatible sources
"""
function resolve_version_conflict(dep1::DependencySpec, dep2::DependencySpec)
    if dep1.name != dep2.name
        throw(DependencyResolutionError(
            dep1.name,
            "Cannot resolve conflict between different dependencies: $(dep1.name) vs $(dep2.name)"
        ))
    end

    # Check for incompatible source types
    # Can't mix git/path/version sources
    source_count = count([
        !isnothing(dep1.git) || !isnothing(dep2.git),
        !isnothing(dep1.path) || !isnothing(dep2.path),
        (!isnothing(dep1.version) && isnothing(dep1.git) && isnothing(dep1.path)) ||
        (!isnothing(dep2.version) && isnothing(dep2.git) && isnothing(dep2.path))
    ])

    if source_count > 1
        # Check if they're actually the same source type
        has_git = !isnothing(dep1.git) && !isnothing(dep2.git)
        has_path = !isnothing(dep1.path) && !isnothing(dep2.path)
        has_version = !isnothing(dep1.version) && !isnothing(dep2.version) &&
                      isnothing(dep1.git) && isnothing(dep2.git) &&
                      isnothing(dep1.path) && isnothing(dep2.path)

        if !has_git && !has_path && !has_version
            @warn "Dependency $(dep1.name) has mixed source types. Using first specification."
        end
    end

    # Resolve version
    version = resolve_version(dep1.version, dep2.version, dep1.name)

    # Merge features
    features = unique(vcat(dep1.features, dep2.features))
    sort!(features)

    # Use first non-nothing git/path (with warning)
    git = dep1.git
    if isnothing(git)
        git = dep2.git
    elseif !isnothing(dep2.git) && dep1.git != dep2.git
        @warn "Git URL conflict for $(dep1.name): $(dep1.git) vs $(dep2.git). Using $(dep1.git)"
    end

    path = dep1.path
    if isnothing(path)
        path = dep2.path
    elseif !isnothing(dep2.path) && dep1.path != dep2.path
        @warn "Path conflict for $(dep1.name): $(dep1.path) vs $(dep2.path). Using $(dep1.path)"
    end

    DependencySpec(
        dep1.name,
        version=version,
        features=features,
        git=git,
        path=path
    )
end

"""
    resolve_version(v1::Union{String, Nothing}, v2::Union{String, Nothing}, name::String) -> Union{String, Nothing}

Resolve version conflict between two version specifications.

# Strategy
1. If both are nothing, return nothing
2. If one is nothing, return the other
3. If both are the same, return that version
4. Prefer more specific version (e.g., "1.0.5" over "1.0")
5. If neither is more specific, use v1 with a warning
"""
function resolve_version(v1::Union{String, Nothing}, v2::Union{String, Nothing}, name::String)
    if isnothing(v1) && isnothing(v2)
        return nothing
    elseif isnothing(v1)
        return v2
    elseif isnothing(v2)
        return v1
    elseif v1 == v2
        return v1
    end

    # Try to determine which is more specific
    specificity1 = version_specificity(v1)
    specificity2 = version_specificity(v2)

    if specificity1 > specificity2
        @debug "Choosing more specific version for $name: $v1 over $v2"
        return v1
    elseif specificity2 > specificity1
        @debug "Choosing more specific version for $name: $v2 over $v1"
        return v2
    else
        @warn "Version conflict for $name: $v1 vs $v2. Using $v1"
        return v1
    end
end

"""
    version_specificity(version::String) -> Int

Calculate a specificity score for a version string.
Higher score = more specific.

# Examples
- "1" -> 1
- "1.0" -> 2
- "1.0.5" -> 3
- "1.0.5-beta" -> 4
"""
function version_specificity(version::String)
    # Handle compound constraints like ">=1.0, <2.0" by splitting on ","
    # and taking the maximum specificity across parts
    constraints = split(version, ',')
    max_score = 0

    for constraint in constraints
        part = strip(constraint)
        # Strip leading operators (^, ~, =, >, <)
        clean_version = replace(part, r"^[\^~=><]+" => "")

        # Count version components
        components = split(clean_version, '.')
        score = length(components)

        # Add point for prerelease/build metadata
        if occursin('-', clean_version) || occursin('+', clean_version)
            score += 1
        end

        max_score = max(max_score, score)
    end

    max_score
end

"""
    validate_dependencies(deps::Vector{DependencySpec})

Validate that all dependencies have valid specifications.

# Checks
1. Each dependency has a name
2. Each dependency has at least one of: version, git, path
3. No duplicate names (use merge_dependencies first)

# Throws
- `DependencyResolutionError` if validation fails
"""
function validate_dependencies(deps::Vector{DependencySpec})
    seen_names = Set{String}()

    for dep in deps
        # Check name
        if isempty(dep.name)
            throw(DependencyResolutionError(
                "(empty)",
                "Dependency must have a name"
            ))
        end

        # Check for duplicates
        if dep.name in seen_names
            throw(DependencyResolutionError(
                dep.name,
                "Duplicate dependency: $(dep.name). Use merge_dependencies first."
            ))
        end
        push!(seen_names, dep.name)

        # Check that at least one source is specified
        if isnothing(dep.version) && isnothing(dep.git) && isnothing(dep.path)
            throw(DependencyResolutionError(
                dep.name,
                "Dependency $(dep.name) must have version, git, or path specified"
            ))
        end

        # Validate version format if present
        if !isnothing(dep.version)
            validate_version_format(dep.version, dep.name)
        end
    end
end

"""
    validate_version_format(version::String, name::String)

Validate that a version string is well-formed.

# Valid formats
- "1.0"
- "1.0.5"
- "^1.0"
- "~1.0.5"
- ">=1.0, <2.0"
- "*"
"""
function validate_version_format(version::String, name::String)
    # Empty version is invalid
    if isempty(strip(version))
        throw(DependencyResolutionError(
            name,
            "Empty version string for $(name)"
        ))
    end

    # Wildcard is valid
    if version == "*"
        return
    end

    # Basic semver pattern (relaxed)
    # Matches: 1, 1.0, 1.0.0, ^1.0, ~1.0.0, >=1.0, etc.
    semver_pattern = r"^[\^~=><]*\d+(\.\d+)*(-[\w.]+)?(\+[\w.]+)?(,\s*[\^~=><]*\d+(\.\d+)*(-[\w.]+)?(\+[\w.]+)?)*$"

    if !occursin(semver_pattern, version)
        @warn "Version string for $name may not be valid semver: $version"
        # Don't throw - let Cargo handle the validation
    end
end

"""
    check_dependency_availability(deps::Vector{DependencySpec}) -> Bool

Check if dependencies are likely to be available on crates.io.
This is a heuristic check - actual availability is confirmed during cargo build.

# Returns
- `true` if dependencies appear valid
- Emits warnings for potentially problematic dependencies
"""
function check_dependency_availability(deps::Vector{DependencySpec})
    all_valid = true

    for dep in deps
        # Check for suspicious characters in names
        if !occursin(r"^[a-zA-Z][a-zA-Z0-9_-]*$", dep.name)
            @warn "Dependency name may be invalid: $(dep.name)"
            all_valid = false
        end

        # Git dependencies should have valid-looking URLs
        if !isnothing(dep.git)
            if !occursin(r"^(https?://|git@)", dep.git)
                @warn "Git URL may be invalid for $(dep.name): $(dep.git)"
                all_valid = false
            end
        end

        # Path dependencies should exist (if we can check)
        if !isnothing(dep.path)
            if !isdir(dep.path)
                @warn "Path dependency may not exist for $(dep.name): $(dep.path)"
                # Don't mark as invalid - could be relative to project
            end
        end
    end

    all_valid
end
