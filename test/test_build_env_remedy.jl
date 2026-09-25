# The remedy a stale build environment names depends on where the module came
# from (#531). A `@rust_crate` module inside a package is rebuilt by
# re-precompiling it; a file written by `write_bindings_to_file` records its
# environment in its own source, so re-precompiling reloads the same record and
# the file has to be written again. Both emitters' `__init__` run the same
# check, and each names the origin its module has.

using Test
using RustCall

include(joinpath(@__DIR__, "bindings_surface.jl"))

const _REMEDY_SAMPLE_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate")

# A record of this crate built under the current environment, except for the
# toolchain: what a file written by an earlier RustCall records once the
# extractor sources have moved.
function _remedy_stale_record(lib_name::String)
    env = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env()]
    return RustCall.CrateBuildRecord(abspath(_REMEDY_SAMPLE_CRATE), lib_name, true, (), true,
                                     :direct, env, "", "stale-toolchain-531", false)
end

# The message `__init__` raises, from the `RustError` inside whatever wraps it.
function _remedy_init_error(f)
    err = try
        f()
        nothing
    catch e
        e
    end
    err === nothing && return nothing
    while err isa LoadError || err isa Base.InitError
        err = err.error
    end
    @test err isa RustCall.RustError
    return sprint(showerror, err)
end

const _REMEDY_RECOMPILE = "Pkg.precompile(; force = true)"

@testset "stale build environment remedy (#531)" begin
    info = RustCall.scan_crate(_REMEDY_SAMPLE_CRATE)
    # The in-memory module declares its library as an include dependency, so
    # the path must name a file; the check refuses before anything loads it.
    lib = touch(joinpath(mktempdir(), "libsample_crate_531.so"))

    @testset "a @rust_crate module is re-precompiled" begin
        record = _remedy_stale_record("rust_crate_remedy531_expr")
        ex = RustCall.emit_crate_module(info, lib; lib_name = record.lib_name,
                                        build_record = record)
        msg = _remedy_init_error(() -> Core.eval(Module(:Remedy531Expr), ex))
        @test msg !== nothing
        @test occursin("<Rust toolchain>", msg)
        @test occursin(_REMEDY_RECOMPILE, msg)
        @test !occursin("write_bindings_to_file", msg)
    end

    @testset "a written bindings file is regenerated" begin
        record = _remedy_stale_record("rust_crate_remedy531_file")
        code = RustCall.emit_crate_module_code(info, lib; module_name = "Remedy531File",
                                               lib_name = record.lib_name,
                                               build_record = record)
        # The file makes the call every 0.7.x makes — the record form with
        # `strict = true` alone — and the check reads it as a written file's.
        # So a file written by v0.7.1 (`RustCall.` instead of the #528 alias)
        # and one written here get the same remedy.
        current = strip(only(filter(l -> occursin("_warn_if_build_env_changed", l),
                                    split(code, '\n'))))
        @test current == "rustcall′RustCall._warn_if_build_env_changed(_BUILD_RECORD; strict = true)"
        # v0.7.1 spelled it through a plain `import RustCall`.
        v071 = replace(code,
                       current => "RustCall._warn_if_build_env_changed(_BUILD_RECORD; strict = true)",
                       "import RustCall as rustcall′RustCall\n" =>
                       "import RustCall as rustcall′RustCall\nimport RustCall\n")
        @test occursin("\nimport RustCall\n", v071)
        for (label, source) in (("written here", code), ("written by v0.7.1", v071))
            @testset "$label" begin
                msg = _remedy_init_error(() -> include_string(Module(:Remedy531Sandbox), source))
                @test msg !== nothing
                @test occursin("<Rust toolchain>", msg)
                @test !occursin(_REMEDY_RECOMPILE, msg)
                # The call the message spells is Julia a user can paste: it
                # parses, and names this crate — a Windows path's backslashes
                # escaped, as `repr` writes them.
                @test occursin(repr(abspath(_REMEDY_SAMPLE_CRATE)), msg)
                call = strip(only(filter(l -> occursin("write_bindings_to_file(", l),
                                         split(msg, '\n'))))
                parsed = Meta.parse(call)
                @test parsed isa Expr && parsed.head === :call
                @test parsed.args[1] == :(RustCall.write_bindings_to_file)
                @test parsed.args[2] == abspath(_REMEDY_SAMPLE_CRATE)
            end
        end
    end

    @testset "a written file makes only calls the oldest 0.7.x accepts (#531 review)" begin
        # A file written by this RustCall is loaded by every RustCall of its
        # format line. `origin = :bindings_file` would be a `MethodError` under
        # v0.7.0 / v0.7.1, whose `_warn_if_build_env_changed` takes `strict`
        # alone; the recorded surface of v0.7.0 says so.
        record = _remedy_stale_record("rust_crate_remedy531_surface")
        code = RustCall.emit_crate_module_code(info, lib; module_name = "Remedy531Surface",
                                               lib_name = record.lib_name,
                                               build_record = record)
        modex = only(filter(x -> x isa Expr && x.head === :module, Meta.parseall(code).args))
        @test isempty(_bindings_surface_findings(modex))
        with_origin = Meta.parseall(replace(code,
            "_warn_if_build_env_changed(_BUILD_RECORD; strict = true)" =>
            "_warn_if_build_env_changed(_BUILD_RECORD; strict = true, origin = :bindings_file)"))
        modex = only(filter(x -> x isa Expr && x.head === :module, with_origin.args))
        findings = _bindings_surface_findings(modex)
        @test length(findings) == 1
        @test occursin("_warn_if_build_env_changed", only(findings))
    end

    @testset "one message, chosen by origin" begin
        record = _remedy_stale_record("rust_crate_remedy531_direct")
        @test_throws ArgumentError RustCall._warn_if_build_env_changed(record; strict = true,
                                                                       origin = :other)
        crate = _remedy_init_error(() -> RustCall._warn_if_build_env_changed(
            record; strict = true, origin = :rust_crate))
        file = _remedy_init_error(() -> RustCall._warn_if_build_env_changed(
            record; strict = true, origin = :bindings_file))
        origin_less = _remedy_init_error(() -> RustCall._warn_if_build_env_changed(
            record; strict = true))
        @test occursin(_REMEDY_RECOMPILE, crate) && !occursin("write_bindings_to_file", crate)
        @test occursin("write_bindings_to_file", file) && !occursin(_REMEDY_RECOMPILE, file)
        @test origin_less == file
        # Only the in-memory module names its origin.
        rc = GlobalRef(RustCall, :_warn_if_build_env_changed)
        @test RustCall._crate_init_prologue(:rust_crate)[1] ==
              :($rc(_BUILD_RECORD; strict = true, origin = :rust_crate))
        @test RustCall._crate_init_prologue(:bindings_file)[1] ==
              :($rc(_BUILD_RECORD; strict = true))
    end
end
