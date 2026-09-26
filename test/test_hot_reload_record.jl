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

include("source_helpers.jl")

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

# The statements of the `__init__` defined in a module expression (or parsed
# source), line numbers stripped.
function _hrr_init_body(ex)
    found = Any[]
    walk(x) = nothing
    function walk(x::Expr)
        if x.head === :function && x.args[1] == :(__init__())
            push!(found, filter(a -> !(a isa LineNumberNode),
                                Base.remove_linenums!(deepcopy(x.args[2])).args))
        end
        foreach(walk, x.args)
    end
    walk(ex)
    return only(found)
end

# The names a module body binds at its root: consts, functions and globals.
function _hrr_root_names(body)
    stmts = Any[]
    flat(x) = x isa Expr && x.head === :block ? foreach(flat, x.args) : push!(stmts, x)
    flat(body)
    defname(sig) = sig isa Symbol ? sig :
                   sig isa Expr && sig.head in (:call, :where, :(::)) ? defname(sig.args[1]) : nothing
    out = Symbol[]
    for st in stmts
        st isa Expr || continue
        if st.head === :const && st.args[1] isa Expr && st.args[1].head === :(=) &&
           st.args[1].args[1] isa Symbol
            push!(out, st.args[1].args[1])
        elseif st.head === :function ||
               (st.head === :(=) && st.args[1] isa Expr && st.args[1].head === :call)
            n = defname(st.args[1])
            n isa Symbol && push!(out, n)
        elseif st.head === :(=) && st.args[1] isa Symbol
            push!(out, st.args[1])
        end
    end
    return unique(out)
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
            # The file names RustCall through its alias (#528).
            Core.eval(m, Meta.parse("import RustCall as rustcall′RustCall"))
            code_record = Core.eval(m, Meta.parse(chopprefix(only(lines), "const _BUILD_RECORD = ")))
            @test code_record == expr_record
            @test expr_record.lib_name == "rust_crate_hrr_474"
            @test expr_record.crate_dir == abspath(info.path)
            @test RustCall.record_build_options(expr_record) == options
            @test expr_record.python == python
            # Both `__init__`s begin with the same prologue — the strict
            # build-environment check, then the mirror registration — and the
            # written file cannot skip the check (#474 review). The in-memory
            # module names its origin, which decides the remedy the check
            # names; the written file makes the origin-less call every 0.7.x
            # accepts, which is read as a written file's (#531).
            expr_prologue = collect(RustCall._crate_init_prologue(:rust_crate))
            code_prologue = collect(RustCall._crate_init_prologue(:bindings_file))
            @test _hrr_init_body(ex)[1:length(expr_prologue)] == expr_prologue
            # The file spells the same statements through its aliases (#528).
            written = [Meta.parse(RustCall._emitted_source(p)) for p in code_prologue]
            @test _hrr_init_body(Meta.parseall(code))[1:length(code_prologue)] == written
            @test expr_prologue[1] == :($(GlobalRef(RustCall, :_warn_if_build_env_changed))(
                _BUILD_RECORD; strict = true, origin = :rust_crate))
            @test code_prologue[1] == :($(GlobalRef(RustCall, :_warn_if_build_env_changed))(
                _BUILD_RECORD; strict = true))
            @test expr_prologue[2:end] == code_prologue[2:end]
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

    # #463 leftover: every root binding either emitter defines is reserved, so a
    # Rust item cannot take its name.
    @testset "every root constant the emitters define is reserved" begin
        info = RustCall.scan_crate(_HRR_SAMPLE_CRATE)
        reserved = Set{Symbol}((RustCall._CRATE_MODULE_HELPERS...,
                                RustCall._CRATE_MODULE_ROOT_CONSTANTS...))
        ex = RustCall.emit_crate_module(info, "/tmp/libhrr463.dylib"; lib_name = "hrr463")
        code = RustCall.emit_crate_module_code(info, "/tmp/libhrr463.dylib"; lib_name = "hrr463",
                                               preload = ["/tmp/libpre463.dylib"])
        body(m) = (m isa Expr && m.head === :module) ? m.args[3] :
                  body(only(filter(a -> a isa Expr && a.head === :module, m.args)))
        for mod_body in (body(ex), body(Meta.parseall(code)))
            names = _hrr_root_names(mod_body)
            # RustCall's own bindings are the `_`-prefixed ones; call-site
            # caches are spelled `#TC#...` and cannot collide (#253).
            own = filter(n -> startswith(String(n), "_"), names)
            @test :_BUILD_RECORD in own
            @test isempty(setdiff(own, reserved))
        end
        # And the reservation is enforced: a Rust item named like one is refused.
        mktempdir() do dir
            for name in RustCall._CRATE_MODULE_ROOT_CONSTANTS
                crate = _hrr_crate(joinpath(dir, String(name) * "_crate"); package = "hrr_res_463",
                                   body = "#[allow(non_snake_case)]\n#[julia]\npub fn $(name)() -> i32 { 1 }\n")
                info = RustCall.scan_crate(crate)
                err = _hrr_error(() -> RustCall.emit_crate_module(info, "/tmp/x.dylib"; lib_name = "x"))
                @test err !== nothing
                err === nothing && @info "not refused" name
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
                    build_options = RustCall.crate_build_options(release = false),
                    snapshot = RustCall.BuildEnvSnapshot())
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
            @test RustCall.bindings_format_compatible(RustCall.BINDINGS_FORMAT_VERSION)
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

    # #474 review: a written module checks its recorded build environment in
    # `__init__`, as the in-memory module does, instead of loading a library
    # built under another `RUSTFLAGS`.
    @testset "a written module refuses a changed build environment at load" begin
        mktempdir() do dir
            crate = _hrr_crate(joinpath(dir, "crate"); package = "hrr_env_written_474",
                               body = "#[julia]\npub fn hrr_e474() -> i32 { 1 }\n")
            out = joinpath(dir, "bindings.jl")
            withenv("RUSTFLAGS" => "--cfg hrr_env474") do
                RustCall.write_bindings_to_file(crate, out; output_module_name = "HrrEnv474")
            end
            host = Module(:HrrEnvHost474)
            Core.eval(host, :(using RustCall))
            err = withenv(() -> _hrr_error(() -> Base.include(host, out)), "RUSTFLAGS" => nothing)
            @test err !== nothing
            @test err !== nothing && occursin("RUSTFLAGS", sprint(showerror, err))
            # Under the recorded environment it loads and calls.
            host2 = Module(:HrrEnvHost474b)
            Core.eval(host2, :(using RustCall))
            withenv("RUSTFLAGS" => "--cfg hrr_env474") do
                Base.include(host2, out)
            end
            m = Base.invokelatest(getglobal, host2, :HrrEnv474)
            try
                @test Base.invokelatest(Base.invokelatest(getglobal, m, :hrr_e474)) == 1
            finally
                RustCall.unload_library(Base.invokelatest(getglobal, m, :_LIB_NAME); close = true)
            end
        end
    end

    # #474 review: the reload checks `ENV` once; if another task changes it
    # while Cargo runs, the probe and the build must still run under the
    # record's environment, never the live one.
    @testset "the probe and the build run under the record's environment, not ENV" begin
        mktempdir() do dir
            crate = _hrr_crate(joinpath(dir, "crate"); package = "hrr_race_474", body = """
                #[cfg(hrr_race474)]
                #[julia]
                pub fn hrr_gated474() -> i32 { 1 }

                #[julia]
                pub fn hrr_plain474() -> i32 { 2 }
                """)
            cargo_home = mkpath(joinpath(dir, "cargo-home"))
            write(joinpath(cargo_home, "config.toml"), "[term]\nverbose = false\n")
            record = withenv(() -> RustCall.crate_build_record(crate, "hrr_race_lib_474";
                                                                snapshot = RustCall.BuildEnvSnapshot()),
                             "RUSTFLAGS" => "--cfg hrr_race474")
            # The reload builds and probes with the one environment it derives
            # from the record; nothing else reaches the two subprocesses.
            src = read(joinpath(pkgdir(RustCall), "src", "hot_reload.jl"), String)
            @test occursin("env = _record_build_subprocess_env(record, snapshot)", src)
            @test occursin("_scan_crate_signatures(record; env = env)", src)
            @test occursin("rebuild_crate(record; env = env)", src)
            # `ENV` changed after the check.
            withenv("RUSTFLAGS" => nothing, "CARGO_PROFILE_RELEASE_OPT_LEVEL" => "1") do
                env = RustCall._record_build_subprocess_env(record, RustCall.BuildEnvSnapshot())
                @test env["RUSTFLAGS"] == "--cfg hrr_race474"
                @test !haskey(env, "CARGO_PROFILE_RELEASE_OPT_LEVEL")
                signatures = RustCall._scan_crate_signatures(record; env = env)
                @test any(s -> s.name == "hrr_gated474", signatures)
                built = RustCall.rebuild_crate(record; env = env)
                image = RustCall.loadable_library_copy(built)
                handle = RustCall.Libdl.dlopen(image)
                try
                    @test RustCall.Libdl.dlsym(handle, "rustcall_hrr_gated474"; throw_error = false) !== nothing
                finally
                    RustCall.Libdl.dlclose(handle)
                end
                # Under the live `ENV` the same pieces would have dropped it.
                @test !any(s -> s.name == "hrr_gated474", RustCall._scan_crate_signatures(record))
            end
            # A `CARGO_HOME` that selects another configuration after the check
            # is refused, not built under.
            err = withenv(() -> _hrr_error(() -> RustCall._record_build_subprocess_env(
                                                    record, RustCall.BuildEnvSnapshot())),
                          "CARGO_HOME" => cargo_home)
            @test err isa ArgumentError
            @test err !== nothing && occursin("Cargo configuration", sprint(showerror, err))
        end
    end

    # #474 review: `@rust_crate` and `write_bindings_to_file` take ONE snapshot
    # before building, build under it, and record that same snapshot; derived
    # inputs (the interpreter `PATH` selected) are pinned, not re-derived.
    @testset "one snapshot decides the build, its key and the record" begin
        crate = _HRR_SAMPLE_CRATE
        record = RustCall.crate_build_record(crate, ""; snapshot = RustCall.BuildEnvSnapshot())
        # The key material read from the record is what the live read gives.
        @test RustCall._plain_crate_build_env(record) == RustCall._plain_crate_build_env()
        # The interpreter `PATH` selected is pinned for the subprocesses.
        pyrec = _hrr_with(record; build_env = ("<PYO3_CONFIG_FILE digest>" => "",
                                               "<pyo3 build interpreter>" => "/recorded/python3",
                                               "<pyo3 build fingerprint>" => "fp"))
        withenv("PYO3_PYTHON" => nothing, "PATH" => mktempdir()) do
            env = RustCall._record_build_subprocess_env(pyrec, RustCall.BuildEnvSnapshot())
            @test env["PYO3_PYTHON"] == "/recorded/python3"
        end
        # A recorded `PYO3_PYTHON` is kept as recorded.
        pinned = _hrr_with(record; build_env = ("PYO3_PYTHON" => "present:/pinned/python",
                                                "<pyo3 build interpreter>" => "/pinned/python"))
        withenv("PYO3_PYTHON" => "/other/python") do
            @test RustCall._record_build_subprocess_env(pinned,
                      RustCall.BuildEnvSnapshot())["PYO3_PYTHON"] == "/pinned/python"
        end
        # An emitter given a record emits that record, and only one named for
        # the module's library.
        info = RustCall.scan_crate(crate)
        named = RustCall._record_named(record, "rust_crate_snap_474")
        ex = RustCall.emit_crate_module(info, "/tmp/libsnap474.dylib";
                                        lib_name = "rust_crate_snap_474", build_record = named)
        @test only(_hrr_record_in(ex)) == named
        code = RustCall.emit_crate_module_code(info, "/tmp/libsnap474.dylib";
                                               lib_name = "rust_crate_snap_474", build_record = named)
        @test occursin("const _BUILD_RECORD = rustcall′" * repr(named), code)
        @test _hrr_error(() -> RustCall.emit_crate_module(info, "/tmp/x.dylib";
                             lib_name = "other", build_record = named)) isa ArgumentError
        # Both entry points build under the snapshot they record.
        src = read_source_tree(joinpath(pkgdir(RustCall), "src", "crate_bindings.jl"))
        @test count("build_env = _record_build_subprocess_env(record, snapshot)", src) == 2
        @test count("env = build_env)", src) >= 4
        @test occursin("build_record = _record_named(record, lib_name)", src)
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
