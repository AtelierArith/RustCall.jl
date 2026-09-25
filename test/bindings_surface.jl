# A file written by `write_bindings_to_file` is loaded by every RustCall of
# its bindings format (`check_bindings_format`: same MAJOR.MINOR, any patch), so
# it may only make calls the oldest release of that line accepts (#531). A
# keyword a later patch added — `origin = :bindings_file` was one — is a
# `MethodError` under the release before it.
#
# `_bindings_surface_findings(modex)` checks a written module against the
# surface recorded from that oldest release
# (`test/fixtures/bindings_surface_<MAJOR.MINOR>.0.txt`, made by
# `test/record_bindings_surface.jl`). Every reference into RustCall must name
# something that release defines, and every call must match one of its methods
# in positional arity and keywords. A format line with no recorded surface
# fails, so a new minor release records one.
#
# Included by the tests that emit written files; not a test file itself.

const _BINDINGS_SURFACE_ROOTS = (Symbol("rustcall′RustCall"), :RustCall)

"""
    _bindings_surface(format = RustCall.BINDINGS_FORMAT_VERSION)

The recorded surface of the oldest release of `format`: name =>
`[(min_arity, vararg, keywords_or_nothing), ...]`, where `nothing` accepts any
keyword. `nothing` when no surface is recorded for the line.
"""
function _bindings_surface(format::AbstractString = RustCall.BINDINGS_FORMAT_VERSION)
    path = joinpath(@__DIR__, "fixtures", "bindings_surface_$(format).0.txt")
    isfile(path) || return nothing
    surface = Dict{Symbol, Vector{Tuple{Int, Bool, Union{Nothing, Set{Symbol}}}}}()
    for line in eachline(path)
        (isempty(line) || startswith(line, '#')) && continue
        fields = split(line, '\t')
        entries = Tuple{Int, Bool, Union{Nothing, Set{Symbol}}}[]
        for entry in fields[2:end]
            arity, kws = split(entry, '|')
            vararg = endswith(arity, '+')
            n = parse(Int, rstrip(arity, '+'))
            accepted = kws == "*" ? nothing : Set(Symbol.(filter(!isempty, split(kws, ','))))
            push!(entries, (n, vararg, accepted))
        end
        surface[Symbol(fields[1])] = entries
    end
    return surface
end

# `RustCall.f` / `rustcall′RustCall.f` -> `:f`; anything else -> `nothing`.
function _bindings_surface_name(x)
    x isa Expr && x.head === :. && length(x.args) == 2 &&
        x.args[1] in _BINDINGS_SURFACE_ROOTS && x.args[2] isa QuoteNode || return nothing
    return x.args[2].value
end

"""
    _bindings_surface_findings(modex::Expr; surface = _bindings_surface()) -> Vector{String}

Every reference of the written module `modex` into RustCall that the oldest
release of its format line would not accept.
"""
function _bindings_surface_findings(modex::Expr; surface = _bindings_surface())
    surface === nothing &&
        return ["no surface recorded for bindings format $(RustCall.BINDINGS_FORMAT_VERSION): " *
                "record it with test/record_bindings_surface.jl under the line's oldest release"]
    findings = String[]
    function check_call(name, args)
        entries = surface[name]
        positional = 0
        splat = false
        kws = Symbol[]
        for a in args
            if a isa Expr && a.head === :parameters
                for p in a.args
                    if p isa Expr && p.head === :kw
                        push!(kws, p.args[1])
                    elseif p isa Symbol
                        push!(kws, p)
                    else
                        splat = true
                    end
                end
            elseif a isa Expr && a.head === :kw
                push!(kws, a.args[1])
            elseif a isa Expr && a.head === :...
                splat = true
            else
                positional += 1
            end
        end
        ok = any(entries) do (n, vararg, accepted)
            arity_ok = splat || (vararg ? positional >= n : positional == n)
            arity_ok && (accepted === nothing || issubset(kws, accepted))
        end
        ok || push!(findings, "`RustCall.$(name)` called with $(positional) positional " *
                              "argument(s) and keywords $(kws): no method of the recorded " *
                              "release accepts that")
    end
    function walk(x)
        x isa Expr || return
        name = _bindings_surface_name(x)
        if name !== nothing
            haskey(surface, name) ||
                push!(findings, "`RustCall.$(name)` is not defined by the recorded release")
            return
        end
        if x.head === :call && (callee = _bindings_surface_name(x.args[1])) !== nothing
            if haskey(surface, callee)
                check_call(callee, x.args[2:end])
            else
                push!(findings, "`RustCall.$(callee)` is not defined by the recorded release")
            end
            foreach(walk, x.args[2:end])
            return
        end
        if (x.head === :import || x.head === :using) && length(x.args) == 1 &&
           x.args[1] isa Expr && x.args[1].head === :(:) &&
           x.args[1].args[1] == Expr(:., :RustCall)
            for p in x.args[1].args[2:end]
                n = p isa Expr && p.head === :as ? p.args[1].args[end] : p.args[end]
                haskey(surface, n) ||
                    push!(findings, "`import RustCall: $(n)`: not defined by the recorded release")
            end
            return
        end
        foreach(walk, x.args)
    end
    walk(modex)
    return unique(findings)
end
