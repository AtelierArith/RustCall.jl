# The remedy a stale build environment names depends on where the module came
# from (#531). A `@rust_crate` module inside a package is rebuilt by
# re-precompiling it; a file written by `write_bindings_to_file` records its
# environment in its own source, so re-precompiling reloads the same record and
# the file has to be written again. Both emitters' `__init__` run the same
# check, and each names the origin its module has.

using Test
using RustCall

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
        # As written by this RustCall, and as written by one that named no
        # origin (v0.7.1 and earlier): the call such a file makes is the
        # record form with `strict = true` alone.
        legacy = "RustCall._warn_if_build_env_changed(_BUILD_RECORD; strict = true)"
        current = only(filter(l -> occursin("_warn_if_build_env_changed", l),
                              split(code, '\n')))
        @test strip(current) != legacy
        for (label, source) in (("current", code),
                                ("legacy", replace(code, strip(current) => legacy)))
            @testset "$label" begin
                label == "legacy" && @test occursin(legacy, source)
                msg = _remedy_init_error(() -> include_string(Module(:Remedy531Sandbox), source))
                @test msg !== nothing
                @test occursin("<Rust toolchain>", msg)
                @test occursin("write_bindings_to_file", msg)
                @test occursin(abspath(_REMEDY_SAMPLE_CRATE), msg)
                @test !occursin(_REMEDY_RECOMPILE, msg)
            end
        end
    end

    @testset "one message, chosen by origin" begin
        record = _remedy_stale_record("rust_crate_remedy531_direct")
        @test_throws ArgumentError RustCall._warn_if_build_env_changed(record; strict = true,
                                                                       origin = :other)
        crate = _remedy_init_error(() -> RustCall._warn_if_build_env_changed(
            record; strict = true, origin = :rust_crate))
        file = _remedy_init_error(() -> RustCall._warn_if_build_env_changed(
            record; strict = true, origin = :bindings_file))
        @test occursin(_REMEDY_RECOMPILE, crate) && !occursin("write_bindings_to_file", crate)
        @test occursin("write_bindings_to_file", file) && !occursin(_REMEDY_RECOMPILE, file)
        # Each emitter's prologue names its own origin.
        @test RustCall._crate_init_prologue(:rust_crate)[1] ==
              :(RustCall._warn_if_build_env_changed(_BUILD_RECORD; strict = true,
                                                    origin = :rust_crate))
        @test RustCall._crate_init_prologue(:bindings_file)[1] ==
              :(RustCall._warn_if_build_env_changed(_BUILD_RECORD; strict = true,
                                                    origin = :bindings_file))
    end
end
