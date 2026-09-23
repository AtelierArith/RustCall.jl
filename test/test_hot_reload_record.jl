# #474: a `@rust_crate` module's own `CrateBuildRecord` is the single source of
# every hot reload rebuild input. Both crate emitters record the same value, the
# module form reads it once and compares — never supplements — caller
# arguments, the current environment is compared with it, and the path form is
# a thin constructor of the same record that checks for a `cdylib` up front.
#
# #473: a failed rescan fails the reload like a failed build.

using Test
using RustCall
using RustToolChain: cargo

const _HRR_SAMPLE_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate")

_hrr_cargo_available() = try
    run(pipeline(`$(cargo()) --version`, devnull))
    true
catch
    false
end

function _hrr_crate(dir::AbstractString; package::AbstractString, cdylib::Bool = true,
                    body::AbstractString, extra::AbstractString = "")
    mkpath(joinpath(dir, "src"))
    runtime = RustCall.rustcall_runtime_crate_path()
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "$(package)"
        version = "0.1.0"
        edition = "2021"

        [lib]
        crate-type = ["$(cdylib ? "cdylib" : "rlib")"]

        [dependencies]
        rustcall_julia_macros = { path = "$(RustCall.escape_toml_string(runtime))" }
        $(extra)
        """)
    _hrr_source!(dir, body)
    return String(dir)
end

_hrr_source!(dir, body) =
    write(joinpath(dir, "src", "lib.rs"), "use rustcall_julia_macros::julia;\n\n" * body)

# The value bound to `const _BUILD_RECORD = ...` in a module expression.
function _hrr_record_in(ex)
    found = Any[]
    walk(x) = nothing
    function walk(x::Expr)
        if x.head === :const && x.args[1] isa Expr && x.args[1].head === :(=) &&
           x.args[1].args[1] === :_BUILD_RECORD
            push!(found, x.args[1].args[2])
        end
        foreach(walk, x.args)
    end
    walk(ex)
    return found
end

function _hrr_stop(name)
    RustCall.is_hot_reload_enabled(name) && RustCall.disable_hot_reload(name)
    delete!(RustCall.HOT_RELOAD_REGISTRY, name)
end

_hrr_error(f) = try
    f()
    nothing
catch e
    e
end

# A module holding `record`, as a generated one does: the module form reads it
# and nothing else.
function _hrr_module_with(record::RustCall.CrateBuildRecord)
    m = Module(:HrrFake474)
    Core.eval(m, :(const _BUILD_RECORD = $record))
    Core.eval(m, :(const _LIB_NAME = _BUILD_RECORD.lib_name))
    return m
end

_hrr_with(r::RustCall.CrateBuildRecord; kwargs...) =
    RustCall.CrateBuildRecord((get(kwargs, f, getfield(r, f))
                               for f in fieldnames(RustCall.CrateBuildRecord))...)

@testset "Hot reload reads the module's build record (#474, #473)" begin

    @testset "the record's source spelling evaluates to an equal record" begin
        r = RustCall.CrateBuildRecord("/crate/with \"quotes\" and \$dollar", "rust_crate_x_1",
                                      false, ("a", "b-c"), false, :direct,
                                      ("RUSTFLAGS" => "--cfg x \"y\"", "<pyo3 build interpreter>" => ""),
                                      "digest", "toolchain\nline", true)
        m = Module(:HrrRepr474)
        Core.eval(m, :(import RustCall))
        back = Core.eval(m, Meta.parse(repr(r)))
        @test back isa RustCall.CrateBuildRecord
        @test back == r
        empty = _hrr_with(r; features = (), build_env = ())
        @test Core.eval(m, Meta.parse(repr(empty))) == empty
        # The record is the only build input a state carries.
        @test RustCall.record_build_options(r) ==
              (release = false, features = ("a", "b-c"), default_features = false, kind = :direct)
    end

    @testset "both crate emitters record the same value" begin
        info = RustCall.scan_crate(_HRR_SAMPLE_CRATE)
        for (python, options) in (
                (false, RustCall.crate_build_options()),
                (false, RustCall.crate_build_options(release = false, features = ["extra"],
                                                     default_features = false)),
                (true, RustCall.crate_build_options(kind = :pyo3_wrapper)))
            kw = (lib_name = "rust_crate_hrr_474", build_options = options, python = python)
            ex = RustCall.emit_crate_module(info, "/tmp/libhrr474.dylib"; kw...)
            code = RustCall.emit_crate_module_code(info, "/tmp/libhrr474.dylib"; kw...)
            in_expr = _hrr_record_in(ex)
            @test length(in_expr) == 1
            expr_record = only(in_expr)
            @test expr_record isa RustCall.CrateBuildRecord
            # The written file: exactly one `_BUILD_RECORD`, read back as source.
            lines = filter(l -> startswith(l, "const _BUILD_RECORD = "), split(code, '\n'))
            @test length(lines) == 1
            m = Module(:HrrCode474)
            Core.eval(m, :(import RustCall))
            code_record = Core.eval(m, Meta.parse(chopprefix(only(lines), "const _BUILD_RECORD = ")))
            @test code_record == expr_record
            @test expr_record.lib_name == "rust_crate_hrr_474"
            @test expr_record.crate_dir == abspath(info.path)
            @test RustCall.record_build_options(expr_record) == options
            @test expr_record.python == python
            # `_LIB_NAME` is read from the record in both, never recorded twice.
            @test occursin("const _LIB_NAME = _BUILD_RECORD.lib_name", code)
            @test occursin("_LIB_NAME = _BUILD_RECORD.lib_name", string(ex))
            for gone in ("_BUILD_OPTIONS", "_BUILD_ENV", "_CRATE_DIR", "_CARGO_CONFIG",
                         "_TOOLCHAIN", "_RECORDS_PYTHON")
                @test !occursin("const $(gone) ", code)
                @test !occursin("const $(gone) ", string(ex))
            end
        end
    end

    @testset "a module without a record is refused" begin
        m = Module(:HrrOld474)
        Core.eval(m, :(const _LIB_NAME = "rust_crate_old_474"))
        err = _hrr_error(() -> RustCall.enable_hot_reload_for_crate(m))
        @test err isa ArgumentError
        @test occursin("_BUILD_RECORD", sprint(showerror, err))
        @test _hrr_error(() -> RustCall.enable_hot_reload_for_crate(Module(:HrrNone474))) isa
              ArgumentError
    end

    if !_hrr_cargo_available()
        @test_skip "cargo not available"
        return
    end

    @testset "every field of the record is compared, and each mismatch is refused" begin
        mktempdir() do dir
            crate = _hrr_crate(joinpath(dir, "crate"); package = "hrr_fields_474",
                               body = "#[julia]\npub fn hrr_value474() -> i32 { 1 }\n",
                               extra = "\n[features]\nextra = []\n")
            other = _hrr_crate(joinpath(dir, "other"); package = "hrr_fields_474",
                               body = "#[julia]\npub fn hrr_value474() -> i32 { 1 }\n",
                               extra = "\n[features]\nextra = []\n")
            # A Cargo home whose configuration differs from the current one.
            cargo_home = mkpath(joinpath(dir, "cargo-home"))
            write(joinpath(cargo_home, "config.toml"), "[build]\nrustflags = [\"--cfg\", \"hrr474\"]\n")

            bindings = @rust_crate crate name = "HrrFields474"
            record = bindings._BUILD_RECORD
            name = record.lib_name
            @test record isa RustCall.CrateBuildRecord
            @test name == bindings._LIB_NAME
            @test record.kind === :direct
            @test realpath(record.crate_dir) == realpath(crate)
            enable(target, args...; kwargs...) =
                RustCall.enable_hot_reload_for_crate(target, args...; poll = true,
                                                     interval = 60.0, kwargs...)
            # One way to contradict each field. The key set is checked against
            # the type, so a field added to the record without a refusal here
            # fails this test.
            refusals = Dict{Symbol, Function}(
                :crate_dir => () -> enable(bindings, other),
                :lib_name => () -> enable(bindings; lib_name = name * "_other"),
                :release => () -> enable(bindings; release = !record.release),
                :features => () -> enable(bindings; features = ["extra"]),
                :default_features => () -> enable(bindings;
                                                  default_features = !record.default_features),
                :kind => () -> enable(_hrr_module_with(_hrr_with(record; kind = :wrapper))),
                :build_env => () -> withenv(() -> enable(bindings),
                                            "RUSTFLAGS" => "--cfg hrr474"),
                :cargo_config => () -> withenv(() -> enable(bindings),
                                               "CARGO_HOME" => cargo_home),
                :toolchain => () -> enable(_hrr_module_with(
                                               _hrr_with(record; toolchain = "another toolchain"))),
                :python => () -> enable(_hrr_module_with(_hrr_with(record; python = !record.python))),
            )
            @test Set(keys(refusals)) == Set(fieldnames(RustCall.CrateBuildRecord))
            try
                for field in fieldnames(RustCall.CrateBuildRecord)
                    err = _hrr_error(refusals[field])
                    @test err isa ArgumentError
                    err isa ArgumentError || @info "not refused" field err
                    @test !haskey(RustCall.HOT_RELOAD_REGISTRY, name)
                    _hrr_stop(name)
                end

                # Arguments that agree with the record are accepted, and the
                # state rebuilds from the module's record itself.
                state = enable(bindings, joinpath(dir, "other", "..", "crate");
                               lib_name = name, release = record.release,
                               features = String[], default_features = record.default_features)
                @test state.record === record
                @test state.lib_name == name
                @test state.build_options == RustCall.record_build_options(record)
                _hrr_stop(name)

                # A reload compares the environment with the record again.
                outcomes = Any[]
                state = enable(bindings; callback = (lib, ok, e) -> push!(outcomes, (ok, e)))
                @test withenv(() -> RustCall.trigger_reload(name), "CARGO_HOME" => cargo_home) == false
                @test last(outcomes)[2] isa ArgumentError
                @test occursin("Cargo configuration", state.last_failure)
            finally
                _hrr_stop(name)
                RustCall.unload_library(name; close = true)
            end
        end
    end

    @testset "the path form constructs the record and requires a cdylib when enabled" begin
        mktempdir() do dir
            rlib = _hrr_crate(joinpath(dir, "rlib"); package = "hrr_rlib_474", cdylib = false,
                              body = "#[julia]\npub fn hrr_r474() -> i32 { 1 }\n")
            before = collect(keys(RustCall.HOT_RELOAD_REGISTRY))
            err = _hrr_error(() -> RustCall.enable_hot_reload_for_crate(rlib; poll = true,
                                                                        interval = 60.0))
            @test err isa ArgumentError
            @test occursin("cdylib", sprint(showerror, err))
            @test sort(collect(keys(RustCall.HOT_RELOAD_REGISTRY))) == sort(before)

            crate = _hrr_crate(joinpath(dir, "crate"); package = "hrr_path_474",
                               body = "#[julia]\npub fn hrr_p474() -> i32 { 1 }\n")
            state = RustCall.enable_hot_reload_for_crate(crate; release = false,
                                                         poll = true, interval = 60.0)
            try
                @test state.record isa RustCall.CrateBuildRecord
                @test state.record.lib_name ==
                      RustCall._crate_hot_reload_name(crate,
                          RustCall.crate_build_options(release = false))
                @test state.record == RustCall.crate_build_record(crate, state.lib_name;
                    build_options = RustCall.crate_build_options(release = false))
            finally
                _hrr_stop(state.lib_name)
            end
        end
    end

    @testset "a written bindings file carries the record the module form reads" begin
        mktempdir() do dir
            crate = _hrr_crate(joinpath(dir, "crate"); package = "hrr_written_474",
                               body = "#[julia]\npub fn hrr_w474() -> i32 { 1 }\n")
            out = joinpath(dir, "bindings.jl")
            RustCall.write_bindings_to_file(crate, out; output_module_name = "HrrWritten474")
            @test occursin("# Bindings format: $(RustCall.BINDINGS_FORMAT_VERSION)", read(out, String))
            @test RustCall.BINDINGS_FORMAT_VERSION >= 13
            host = Module(:HrrWrittenHost474)
            Core.eval(host, :(using RustCall))
            Base.include(host, out)
            m = Base.invokelatest(getglobal, host, :HrrWritten474)
            record = Base.invokelatest(getglobal, m, :_BUILD_RECORD)
            name = record.lib_name
            try
                @test record isa RustCall.CrateBuildRecord
                @test realpath(record.crate_dir) == realpath(crate)
                @test _hrr_error(() -> RustCall.enable_hot_reload_for_crate(m, dir)) isa
                      ArgumentError
                state = RustCall.enable_hot_reload_for_crate(m; poll = true, interval = 60.0)
                @test state.record === record
                _hrr_source!(crate, "#[julia]\npub fn hrr_w474() -> i32 { 2 }\n")
                @test RustCall.trigger_reload(name) == true
                @test Base.invokelatest(Base.invokelatest(getglobal, m, :hrr_w474)) == 2
            finally
                _hrr_stop(name)
                RustCall.unload_library(name; close = true)
            end
        end
    end

    # #473: extraction refuses a `#[julia]` item in an unmarked inline module,
    # which Cargo compiles — so the rescan fails while the build would succeed.
    @testset "a failed rescan fails the reload and keeps the previous image (#473)" begin
        mktempdir() do dir
            crate = _hrr_crate(joinpath(dir, "crate"); package = "hrr_rescan_473",
                               body = "#[julia]\npub fn hrr_value473() -> i32 { 1 }\n")
            bindings = @rust_crate crate name = "HrrRescan473"
            name = bindings._LIB_NAME
            outcomes = Any[]
            try
                state = RustCall.enable_hot_reload_for_crate(bindings; poll = true,
                    interval = 60.0, callback = (lib, ok, e) -> push!(outcomes, (ok, e)))
                @test Base.invokelatest(bindings.hrr_value473) == 1
                current = RustCall.RUST_LIBRARIES[name]
                lib_path = state.lib_path
                generation = state.generation

                _hrr_source!(crate, """
                    #[julia]
                    pub fn hrr_value473() -> i32 { 2 }

                    mod inner {
                        use rustcall_julia_macros::julia;
                        #[julia]
                        pub fn hrr_inner473() -> i32 { 3 }
                    }
                    """)
                # The premise: the scan fails, and Cargo builds these sources.
                @test _hrr_error(() -> RustCall.scan_crate(crate)) isa RustCall.ExtractorError
                @test isfile(RustCall.rebuild_crate(state.record))

                @test RustCall.trigger_reload(name) == false
                @test occursin("inline module", state.last_failure)
                @test last(outcomes)[1] == false
                @test last(outcomes)[2] isa RustCall.ExtractorError
                # The previous image is still the current one.
                @test RustCall.RUST_LIBRARIES[name] == current
                @test state.lib_path == lib_path
                @test state.generation == generation
                @test Base.invokelatest(bindings.hrr_value473) == 1

                # The same failure again is not reported anew, and a fix reloads.
                failure = state.last_failure
                @test RustCall.trigger_reload(name) == false
                @test state.last_failure == failure
                _hrr_source!(crate, "#[julia]\npub fn hrr_value473() -> i32 { 4 }\n")
                @test RustCall.trigger_reload(name) == true
                @test state.last_failure == ""
                @test last(outcomes) == (true, nothing)
                @test Base.invokelatest(bindings.hrr_value473) == 4
            finally
                _hrr_stop(name)
                RustCall.unload_library(name; close = true)
            end
        end
    end
end
