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
