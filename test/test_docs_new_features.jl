# Runs the code of docs/src/tutorial_new_features.md as written on the page,
# so the tutorial cannot drift from what RustCall does. The `@example` blocks
# are also run by the docs build; the facade section is not (it builds a Cargo
# workspace), so it is only checked here.

using Test
using RustCall

const NEW_FEATURES_PAGE = joinpath(@__DIR__, "..", "docs", "src", "tutorial_new_features.md")

# The fenced blocks of the page, in order, as (info string, body) pairs.
function _fenced_blocks(path)
    blocks = Tuple{String,String}[]
    info = nothing
    body = IOBuffer()
    for line in eachline(path)
        if info === nothing
            if startswith(line, "```")
                info = strip(line[4:end])
                body = IOBuffer()
            end
        elseif rstrip(line) == "```"
            push!(blocks, (String(info), String(take!(body))))
            info = nothing
        else
            println(body, line)
        end
    end
    return blocks
end

_run_block(mod, code) = Base.include_string(mod, code, NEW_FEATURES_PAGE)

const NEW_FEATURE_BLOCKS = _fenced_blocks(NEW_FEATURES_PAGE)

@testset "tutorial_new_features.md: @example blocks" begin
    mod = Module(:NewFeaturesTutorial)
    examples = [code for (info, code) in NEW_FEATURE_BLOCKS
                if info in ("@setup new_features", "@example new_features")]
    @test length(examples) >= 15
    for code in examples
        _run_block(mod, code)
    end
    value(name) = Base.invokelatest(getfield, mod, name)
    call(name, args...) = Base.invokelatest(value(name), args...)

    @test call(:balance, value(:acc)) == 100
    @test value(:refused).value == "negative opening balance: -5"
    @test (call(:cents, value(:alice)), call(:cents, value(:bob))) == (60, 40)
    @test_throws ArgumentError call(:take_from, value(:alice), value(:alice), 1)
    @test call(:combined, value(:alice), value(:alice)) == 120
    @test (call(:beans, value(:jar)), call(:beans, value(:small))) == (100, 0)
    @test call(:total_beans, value(:jar), nothing) == 100
    @test_throws ArgumentError call(:total_beans, value(:jar), C_NULL)
    @test value(:y) == [3.0, 5.0, 7.0]
    @test call(:norm2, [3.0, 4.0]) == 5.0
    @test_throws ArgumentError call(:norm2, [1, 2])
    @test_throws ArgumentError call(:axpy, 1.0, value(:y), value(:y))
    @test RustCall.is_err(call(:axpy, 1.0, [1.0], value(:y)))
end

# Runs the facade section's usage block line by line in `mod`. A trailing
# `# <literal>` comment is the value the line must produce, and `# ArgumentError`
# marks a line that must throw it; any other comment is prose.
function _run_usage_block(mod, code)
    # `Core.eval`, not `include_string`, so a line's exception is not wrapped
    # in a `LoadError`.
    run(stmt) = Core.eval(mod, Meta.parse(stmt))
    checked = 0
    for line in split(code, '\n')
        isempty(strip(line)) && continue
        stmt, comment = occursin("  # ", line) ? split(line, "  # "; limit = 2) : (line, "")
        comment = strip(comment)
        if startswith(comment, "ArgumentError")
            @test_throws ArgumentError run(stmt)
            checked += 1
            continue
        end
        expected = isempty(comment) ? nothing : Meta.parse(comment; raise = false)
        literal = expected isa Union{Number,String} ||
                  (expected isa Expr && expected.head === :tuple &&
                   all(x -> x isa Union{Number,String}, expected.args))
        value = run(stmt)
        if literal
            @test isequal(value, Core.eval(Main, expected))
            checked += 1
        end
    end
    return checked
end

@testset "tutorial_new_features.md: generate_crate_instances facade" begin
    rust_sources = [code for (info, code) in NEW_FEATURE_BLOCKS
                    if info == "rust" && occursin("pub struct Accumulator<T>", code)]
    julia_specs = [code for (info, code) in NEW_FEATURE_BLOCKS
                   if info == "julia" && occursin("generate_crate_instances(instances)", code)]
    tomls = [code for (info, code) in NEW_FEATURE_BLOCKS
             if info == "toml" && occursin("name = \"stats_facade\"", code)]
    usages = [code for (info, code) in NEW_FEATURE_BLOCKS
              if info == "julia" && occursin("@rust_crate \"stats_facade\"", code)]
    @test length(rust_sources) == 1
    @test length(julia_specs) == 1
    @test length(tomls) == 1
    @test length(usages) == 1

    mktempdir() do root
        native = joinpath(root, "stats")
        mkpath(joinpath(native, "src"))
        write(joinpath(native, "Cargo.toml"), """
            [package]
            name = "stats"
            version = "0.1.0"
            edition = "2021"
            """)
        write(joinpath(native, "src", "lib.rs"), only(rust_sources))

        mod = Module(:NewFeaturesFacade)
        cd(() -> _run_block(mod, only(julia_specs)), root)
        facade = joinpath(root, "stats_facade")
        generated = read(joinpath(facade, "src", "lib.rs"), String)
        @test occursin("pub fn merge(&mut self, other: &FloatAcc) -> ()", generated)
        @test occursin("#[rustcall_owned_return(Summary)]", generated)

        # The page depends on the published macro crate; the test uses this
        # checkout's, so it runs offline and against the current sources.
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        toml = replace(only(tomls), "rustcall_julia_macros = \"0.7\"" =>
            "rustcall_julia_macros = { path = \"$runtime\" }")
        @test toml != only(tomls)
        write(joinpath(facade, "Cargo.toml"), toml)

        mod = Module(:NewFeaturesFacadeUsage)
        Core.eval(mod, :(using RustCall))
        try
            # Four lines with a value comment, two with `# ArgumentError`.
            @test cd(() -> _run_usage_block(mod, only(usages)), root) == 6
        finally
            for name in (:a, :b, :s, :i)
                isdefined(mod, name) && finalize(getfield(mod, name))
            end
            if isdefined(mod, :S)
                S = getfield(mod, :S)
                RustCall.unload_library(
                    Base.invokelatest(getfield, getfield(S, :module_ref), :_LIB_NAME); close = true)
            end
        end
    end
end
