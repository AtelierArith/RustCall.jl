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
        elseif line == "```"
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

# The usage block of the facade section, with its comments as assertions.
# Called through `invokelatest`: the facade's types are newer than the testset.
function _exercise_stats_facade(S, made)
    a = S.FloatAcc(0.0); push!(made, a)
    S.push(a, 1.0); S.push(a, 3.0)
    b = S.FloatAcc(0.0); push!(made, b)
    S.push(b, 5.0)
    S.merge(a, b)
    @test S.mean(a) == 3.0
    s = S.snapshot(a); push!(made, s)
    @test (S.mean(s), S.count(s)) == (3.0, UInt64(3))
    @test S.checked_snapshot(S.FloatAcc(0.0)).value == "no samples yet"
    @test RustCall.is_ok(S.checked_snapshot(a))
    i = S.IntAcc(10); push!(made, i)
    S.push(i, 5)
    @test S.total(i) == 15
    @test_throws ArgumentError S.merge(a, a)
    @test_throws ArgumentError S.merge(a, i)
    return nothing
end

@testset "tutorial_new_features.md: generate_crate_instances facade" begin
    rust_sources = [code for (info, code) in NEW_FEATURE_BLOCKS
                    if info == "rust" && occursin("pub struct Accumulator<T>", code)]
    julia_specs = [code for (info, code) in NEW_FEATURE_BLOCKS
                   if info == "julia" && occursin("generate_crate_instances(instances)", code)]
    tomls = [code for (info, code) in NEW_FEATURE_BLOCKS
             if info == "toml" && occursin("name = \"stats_facade\"", code)]
    @test length(rust_sources) == 1
    @test length(julia_specs) == 1
    @test length(tomls) == 1

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

        S = Core.eval(@__MODULE__, :(@rust_crate $facade))
        made = Any[]
        try
            Base.invokelatest(_exercise_stats_facade, S, made)
        finally
            foreach(finalize, made)
            RustCall.unload_library(
                Base.invokelatest(getfield, getfield(S, :module_ref), :_LIB_NAME); close = true)
        end
    end
end
