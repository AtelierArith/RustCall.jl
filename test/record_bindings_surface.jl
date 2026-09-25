# Record the surface of the loaded RustCall that a written bindings file can
# call (#531). Not a test: run it once per bindings format line, under a checkout
# of that line's oldest release, and commit the output, which
# `test/bindings_surface.jl` checks every written file against:
#
#     julia --project=<checkout of vX.Y.0> test/record_bindings_surface.jl \
#         test/fixtures/bindings_surface_X.Y.0.txt
using RustCall
v = pkgversion(RustCall)
out = ARGS[1]
# Its own and imported names, and the modules it binds with `using` (`Libdl`),
# which `names` does not list.
modules_ = [nameof(m) for m in values(Base.loaded_modules)
            if isdefined(RustCall, nameof(m)) && getfield(RustCall, nameof(m)) === m]
names_ = sort(unique(filter(n -> isdefined(RustCall, n) && !startswith(string(n), "#"),
                            vcat(names(RustCall; all = true, imported = true), modules_))))

# One entry per method: its positional arity (`n`, or `n+` for a vararg method
# taking at least n) and the keywords it accepts (`*` for a `kwargs...`
# method). The methods Julia generates for default positional arguments show
# their keywords as `...`: they forward them to the full method of the same
# definition, whose keywords they therefore accept.
function signatures(x)
    ms = collect(methods(x))
    kw_of = Dict{Tuple{Symbol, Int32}, Vector{Symbol}}()
    for m in ms
        k = Base.kwarg_decl(m)
        (isempty(k) || k != [Symbol("...")]) && (kw_of[(m.file, m.line)] = k)
    end
    sigs = String[]
    for m in ms
        k = Base.kwarg_decl(m)
        k == [Symbol("...")] && (k = get(kw_of, (m.file, m.line), Symbol[]))
        kws = any(s -> endswith(string(s), "..."), k) ? "*" : join(sort(string.(k)), ",")
        npos = m.nargs - 1
        push!(sigs, (m.isva ? "$(npos - 1)+" : string(npos)) * "|" * kws)
    end
    return sort(unique(sigs))
end

open(out, "w") do io
    println(io, "# The surface of RustCall $(v) that a file written by `write_bindings_to_file`")
    println(io, "# can reach, recorded from the v$(v) release. v$(v) is the oldest release of")
    println(io, "# bindings format $(v.major).$(v.minor), and every file of that format must load")
    println(io, "# under it (#531). One line per name: the name, then one entry per")
    println(io, "# method, `arity|keywords`: `n` positional arguments, or `n+` for a")
    println(io, "# vararg method taking at least n; the keywords it accepts, `*` for any.")
    println(io, "# A name with no entries is not callable (a module, a constant).")
    for n in names_
        x = getfield(RustCall, n)
        sigs = (x isa Function || x isa Type) ? signatures(x) : String[]
        println(io, join([string(n); sigs], '\t'))
    end
end
println("recorded ", length(names_), " names from RustCall ", v)
