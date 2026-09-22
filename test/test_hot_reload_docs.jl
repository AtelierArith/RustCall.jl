# The hot reload documentation runs as written (#465): the runnable example of
# docs/src/hot_reload.md, and the examples in the docstrings of
# `enable_hot_reload` and `enable_hot_reload_for_crate`. Each is read from where
# a user reads it — the page, the docstring — and executed, so neither can drift
# from what RustCall does.

using Test
using RustCall
using RustToolChain: cargo

const _HRD_GUIDE = joinpath(dirname(@__DIR__), "docs", "src", "hot_reload.md")

_hrd_cargo_available() = try
    run(pipeline(`$(cargo()) --version`, devnull))
    true
catch
    false
end

# The `@setup <name>` / `@example <name>` blocks of a Documenter page, in page
# order: what Documenter evaluates, in one module, when it builds the page.
function _hrd_example_blocks(path::AbstractString, name::AbstractString)
    blocks = String[]
    open_block = nothing
    for line in eachline(path)
        if open_block === nothing
            (startswith(line, "```@setup $(name)") ||
             startswith(line, "```@example $(name)")) || continue
            open_block = IOBuffer()
        elseif startswith(line, "```")
            push!(blocks, String(take!(open_block)))
            open_block = nothing
        else
            println(open_block, line)
        end
    end
    open_block === nothing || error("unterminated example block in $(path)")
    return blocks
end

# The ```julia code blocks of a binding's docstring, from the docstring's own
# text as the docsystem stores it (every method's docstring of the binding).
function _hrd_docstring_julia_blocks(name::Symbol)
    multidoc = Base.Docs.meta(RustCall)[Base.Docs.Binding(RustCall, name)]
    blocks = String[]
    for sig in multidoc.order
        text = join(multidoc.docs[sig].text)
        open_block = nothing
        for line in split(text, '\n')
            if open_block === nothing
                startswith(line, "```julia") && (open_block = IOBuffer())
            elseif startswith(line, "```")
                push!(blocks, String(take!(open_block)))
                open_block = nothing
            else
                println(open_block, line)
            end
        end
    end
    return blocks
end

# A `#[julia]` crate that is its own cdylib, as the docstrings require.
function _hrd_crate(dir::AbstractString, package::AbstractString, value::Integer)
    mkpath(joinpath(dir, "src"))
    runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "$(package)"
        version = "0.1.0"
        edition = "2021"

        [lib]
        crate-type = ["cdylib"]

        [features]
        simd = []

        [dependencies]
        rustcall_julia_macros = { path = "$(runtime)" }
        """)
    # Returns `value`, plus 100 when built with the `simd` feature: a reload
    # that dropped the module's features would be visible in the result.
    write(joinpath(dir, "src", "lib.rs"), """
        use rustcall_julia_macros::julia;

        #[julia]
        pub fn $(package)_value() -> i32 {
            if cfg!(feature = "simd") { $(value) + 100 } else { $(value) }
        }
        """)
    return String(dir)
end

_hrd_get(m::Module, name::Symbol) = Base.invokelatest(getfield, m, name)

function _hrd_forget(lib_name::AbstractString)
    RustCall.is_hot_reload_enabled(lib_name) && RustCall.disable_hot_reload(lib_name)
    lock(RustCall.REGISTRY_LOCK) do
        delete!(RustCall.HOT_RELOAD_REGISTRY, lib_name)
    end
    haskey(RustCall.RUST_LIBRARIES, lib_name) && RustCall.unload_library(lib_name)
    return nothing
end

# Runs a docstring's example with its placeholder crate path replaced by a real
# crate, and nothing else changed.
function _hrd_run_docstring(name::Symbol, crate::AbstractString)
    blocks = _hrd_docstring_julia_blocks(name)
    @test length(blocks) == 1
    code = only(blocks)
    placeholder = "\"path/to/my_crate\""
    @test count(placeholder, code) == 1
    sandbox = Module(Symbol("HotReloadDocstring_", name))
    Core.eval(sandbox, :(using RustCall))
    include_string(sandbox, replace(code, placeholder => repr(String(crate))),
                   "docstring of RustCall.$(name)")
    return sandbox
end

@testset "Hot reload documentation runs as written (#465)" begin
    if !_hrd_cargo_available()
        @test_skip "cargo not available"
    else
        @testset "docs/src/hot_reload.md example" begin
            blocks = _hrd_example_blocks(_HRD_GUIDE, "hotreload")
            @test length(blocks) >= 4
            joined = join(blocks, '\n')
            @test occursin("@rust_crate", joined)
            @test occursin("RustCall.enable_hot_reload_for_crate(", joined)
            @test occursin("RustCall.disable_hot_reload(", joined)

            sandbox = Module(:HotReloadGuideSandbox)
            lib_name = nothing
            try
                for block in blocks
                    include_string(sandbox, block, "docs/src/hot_reload.md")
                    Base.invokelatest(isdefined, sandbox, :state) &&
                        (lib_name = _hrd_get(sandbox, :state).lib_name)
                end
                @test _hrd_get(sandbox, :first_step) == 1
                # The watcher (not a manual trigger) rebuilt the crate, and the
                # module `@rust_crate` generated now calls the new library.
                @test _hrd_get(sandbox, :rebuilt) === true
                @test _hrd_get(sandbox, :second_step) == 2
                @test lib_name == _hrd_get(sandbox, :HotCounter)._LIB_NAME
                @test !RustCall.is_hot_reload_enabled(lib_name)
            finally
                lib_name === nothing || _hrd_forget(lib_name)
            end
        end

        @testset "enable_hot_reload docstring example" begin
            crate = _hrd_crate(joinpath(mktempdir(), "c"), "hrd_plain", 11)
            sandbox = _hrd_run_docstring(:enable_hot_reload, crate)
            lib_name = _hrd_get(sandbox, :lib_name)
            try
                mod = _hrd_get(sandbox, :MyCrate)
                state = _hrd_get(sandbox, :state)
                @test lib_name == mod._LIB_NAME
                @test state.lib_name == lib_name
                # `trigger_reload` rebuilt and swapped the library: a failed
                # reload leaves `generation` at 0 and records its error.
                @test state.generation > 0
                @test isempty(state.last_failure)
                @test !RustCall.is_hot_reload_enabled(lib_name)
                @test Base.invokelatest(mod.hrd_plain_value) == 11
            finally
                _hrd_forget(lib_name)
            end
        end

        @testset "enable_hot_reload_for_crate docstring example" begin
            crate = _hrd_crate(joinpath(mktempdir(), "c"), "hrd_module", 22)
            sandbox = _hrd_run_docstring(:enable_hot_reload_for_crate, crate)
            state = _hrd_get(sandbox, :state)
            try
                mod = _hrd_get(sandbox, :MyCrate)
                @test state.lib_name == mod._LIB_NAME
                @test state.generation > 0
                @test isempty(state.last_failure)
                @test !RustCall.is_hot_reload_enabled(state.lib_name)
                # The docstring loads with `features=["simd"]`; the reload kept
                # them (#465 review): the rebuilt library still has the feature.
                @test collect(state.build_options.features) == ["simd"]
                @test Base.invokelatest(mod.hrd_module_value) == 122
            finally
                _hrd_forget(state.lib_name)
            end
        end
    end
end
