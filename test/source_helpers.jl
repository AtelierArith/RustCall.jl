const _TEST_SOURCE_ROOT = normpath(joinpath(@__DIR__, "..", "src"))

"""Resolve a source file by a path relative to `src/` or by its basename."""
function _test_source_path(file::AbstractString)
    path = normpath(joinpath(_TEST_SOURCE_ROOT, file))
    isfile(path) && return path

    matches = String[]
    for (root, _, files) in walkdir(_TEST_SOURCE_ROOT)
        basename(file) in files && push!(matches, joinpath(root, basename(file)))
    end
    length(matches) == 1 || throw(ArgumentError(
        "expected one RustCall source file named $(basename(file)); found $(length(matches))"
    ))
    return only(matches)
end

"""Return every Julia source file below `src/` relative to that directory."""
function _test_source_files()
    return [
        relpath(joinpath(root, file), _TEST_SOURCE_ROOT)
        for (root, _, files) in walkdir(_TEST_SOURCE_ROOT)
        for file in files
        if endswith(file, ".jl")
    ]
end

# Source-level safety checks must follow component includes, just as Julia does.
# Only literal top-level includes are followed: quoted generated code and
# includes inside functions are not definitions loaded with the source file.
function read_source_tree(path::AbstractString)
    source = read(path, String)
    parts = String[source]
    for ex in Meta.parseall(source; filename = path).args
        ex isa Expr && ex.head === :call && length(ex.args) == 2 || continue
        ex.args[1] === :include && ex.args[2] isa String || continue
        push!(parts, read_source_tree(joinpath(dirname(path), ex.args[2])))
    end
    return join(parts, "\n")
end
