# Regression tests for #461: the `@rust_crate` / build paths — written
# bindings, the plain wrapper crate's name, hot reload's registry name and
# build, process-global `cd`, the PyO3 host key, `RUSTCALL_OFFLINE`, and the
# written file's `Libdl` import.

using Test
using RustCall
using RustToolChain: cargo

const _CBP_ROOT = dirname(@__DIR__)
const _CBP_HOST_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_host")

_cbp_cargo_available() = try
    run(pipeline(`$(cargo()) --version`, devnull))
    true
catch
    false
end

# A `#[julia]` crate in a directory of its own. `package` may be hyphenated and
# `lib_name` renames the library target, which are the two spellings a package
# name alone gets wrong. `extra_deps` is appended to `[dependencies]`.
function _cbp_crate(dir::AbstractString; package::AbstractString,
                    lib_name::Union{Nothing, AbstractString} = nothing,
                    cdylib::Bool = true, body::AbstractString,
                    extra_deps::AbstractString = "")
    mkpath(joinpath(dir, "src"))
    runtime = RustCall.rustcall_runtime_crate_path()
    lib = "[lib]\n"
    lib_name === nothing || (lib *= "name = \"$(lib_name)\"\n")
    lib *= cdylib ? "crate-type = [\"cdylib\"]\n" : "crate-type = [\"rlib\"]\n"
    write(joinpath(dir, "Cargo.toml"), """
        [package]
        name = "$(package)"
        version = "0.1.0"
        edition = "2021"

        $(lib)
        [dependencies]
        rustcall_julia_macros = { path = "$(RustCall.escape_toml_string(runtime))" }
        $(extra_deps)
        """)
    write(joinpath(dir, "src", "lib.rs"), """
        use rustcall_julia_macros::julia;

        $(body)
        """)
    return String(dir)
end

# `pwd()` as seen by *another* task for the whole length of `f()`: `f` runs in
# a task of its own, and this one samples the working directory every time it
# gets to run — which it does whenever `f` waits on a subprocess.
function _cbp_cwd_seen_during(f)
    seen = Set{String}()
    task = @async f()
    while !istaskdone(task)
        push!(seen, pwd())
        sleep(0.005)
    end
    push!(seen, pwd())
    result = try
        fetch(task)
    catch e
        e isa TaskFailedException ? e.task.exception : rethrow()
    end
    return seen, result
end

# A dependency no registry has: under `--offline` Cargo fails at resolution,
# at once, and says it is offline; without the flag it would go to the network.
const _CBP_MISSING_DEP = "rustcall_nonexistent_crate_461 = \"=0.0.1\""

@testset "Crate build paths (#461)" begin
    @testset "wrapper lib.rs names the crate by its Rust identifier (item 2)" begin
        mktempdir() do dir
            crate = _cbp_crate(joinpath(dir, "c"); package = "cbp-hyphen-461",
                               lib_name = "cbp_renamed_461", cdylib = false,
                               body = "#[julia]\npub fn cbp_one() -> i32 { 1 }\n")
            info = RustCall.CrateInfo("cbp-hyphen-461", crate, "0.1.0",
                                      RustCall.DependencySpec[],
                                      RustCall.RustFunctionSignature[],
                                      RustCall.RustStructInfo[], String[])
            src = RustCall.generate_wrapper_lib_rs(info)
            @test occursin("use cbp_renamed_461::*;", src)
            @test !occursin("use cbp-hyphen-461", src)

            # Without a `[lib] name` it is the package name with `-` mapped.
            crate2 = _cbp_crate(joinpath(dir, "d"); package = "cbp-plain-461", cdylib = false,
                                body = "")
            info2 = RustCall.CrateInfo("cbp-plain-461", crate2, "0.1.0",
                                       RustCall.DependencySpec[],
                                       RustCall.RustFunctionSignature[],
                                       RustCall.RustStructInfo[], String[])
            @test occursin("use cbp_plain_461::*;", RustCall.generate_wrapper_lib_rs(info2))
        end
    end

    @testset "written bindings import Libdl through RustCall (item 8)" begin
        info = RustCall.CrateInfo("cbp_libdl_461", "/nonexistent", "0.1.0",
                                  RustCall.DependencySpec[],
                                  RustCall.RustFunctionSignature[],
                                  RustCall.RustStructInfo[], String[])
        code = RustCall.emit_crate_module_code(info, "/nonexistent/lib.so";
                                               lib_name = "cbp_libdl_461")
        @test occursin("\nimport RustCall.Libdl\n", code)
        @test !occursin("\nimport Libdl\n", code)
        # The file still parses, and every `Libdl.` it names is the one
        # imported through RustCall.
        @test Meta.parseall(code) isa Expr
    end

    @testset "PyO3 host key includes the build environment (item 6)" begin
        if !isdir(_CBP_HOST_CRATE)
            @test_skip "PyO3 host fixture not found"
        else
            info = RustCall.scan_crate(_CBP_HOST_CRATE)
            key(env...) = withenv(env...) do
                RustCall._pyo3_extension_artifact(mktempdir(), info, "m", "/usr/bin/python3",
                                                  ".so", "fp").key
            end
            base = key("RUSTFLAGS" => nothing, "PYO3_PYTHON" => nothing)
            @test key("RUSTFLAGS" => nothing, "PYO3_PYTHON" => nothing) == base
            @test key("RUSTFLAGS" => "-C opt-level=1", "PYO3_PYTHON" => nothing) != base
            # The build sets `PYO3_PYTHON` to the interpreter it was handed, so
            # an ambient value is not an input; the interpreter is.
            @test key("RUSTFLAGS" => nothing, "PYO3_PYTHON" => "/elsewhere/python") == base
            @test withenv("RUSTFLAGS" => nothing, "PYO3_PYTHON" => nothing) do
                RustCall._pyo3_extension_artifact(mktempdir(), info, "m", "/other/python3",
                                                  ".so", "fp").key
            end != base
        end
    end

    @testset "a reload failure's fingerprint ignores Cargo's status lines (item 4)" begin
        # `rebuild_crate` now fails with a `CargoBuildError` carrying Cargo's
        # stderr; a lock wait or a `Compiling` line must not make one compile
        # error look like a new failure on the next attempt.
        error_text = "error: expected one of `!`, found `is`\n --> src/lib.rs:2:45\n"
        quiet = RustCall.CargoBuildError("Cargo build failed", error_text, "/p")
        noisy = RustCall.CargoBuildError("Cargo build failed",
            "    Blocking waiting for file lock on package cache\n" *
            "   Compiling dep v1.0.0\n" * error_text, "/p")
        other = RustCall.CargoBuildError("Cargo build failed",
                                         "error: something else\n", "/p")
        fp = RustCall._reload_failure_fingerprint
        @test fp(quiet) == fp(noisy)
        @test fp(quiet) != fp(other)
        @test fp(ErrorException("x")) == sprint(showerror, ErrorException("x"))
    end

    @testset "Cargo probes pass --offline under RUSTCALL_OFFLINE (item 7, source level)" begin
        # These probes swallow Cargo's failure by design — they answer "" or
        # `nothing` and the caller falls back — so the flag is not observable
        # from outside; the source is where it can be asserted. The builds,
        # whose failures do surface, are checked by behaviour below.
        pyo3_src = read(joinpath(_CBP_ROOT, "src", "pyo3.jl"), String)
        manifest_src = read(joinpath(_CBP_ROOT, "src", "manifest.jl"), String)
        function body(src, name)
            start = findfirst("function $(name)(", src)
            @test start !== nothing
            stop = findnext("\nend\n", src, last(start))
            return src[first(start):last(stop)]
        end
        probe = body(pyo3_src, "_wrapper_probe_context")
        @test occursin("network = _cargo_network_args()", probe)
        @test occursin("rustc -q \$flag \$network", probe)
        @test occursin("pkgid \$network", probe)
        @test occursin("_cargo_network_args()", body(pyo3_src, "_cargo_package_metadata"))
        @test occursin("_cargo_network_args()", body(pyo3_src, "_cargo_resolved_features"))
        @test occursin("_cargo_network_args()", body(pyo3_src, "_resolved_pyo3_dependency"))
        @test occursin("_cargo_network_args()", body(manifest_src, "_crate_build_cfg_text"))
    end

    if !_cbp_cargo_available()
        @test_skip "Cargo not available, skipping the build-path tests of #461"
        return
    end

    @testset "builds keep the process working directory (item 5)" begin
        mktempdir() do dir
            project = RustCall.create_cargo_project("cbp_cwd_461", RustCall.DependencySpec[])
            try
                write(joinpath(project.path, "src", "lib.rs"),
                      "#[no_mangle]\npub extern \"C\" fn cbp_cwd() -> i32 { 461 }\n")
                here = pwd()
                seen, built = _cbp_cwd_seen_during(() -> RustCall.build_cargo_project(project))
                @test seen == Set([here])
                @test built isa String && isfile(built)
            finally
                RustCall.cleanup_cargo_project(project)
            end

            # The PyO3 host build, run into a resolution failure so it needs
            # no Python: it too must not move the other task's directory, and
            # it carries `--offline` (item 7).
            host = _cbp_crate(joinpath(dir, "host"); package = "cbp_host_461",
                              body = "", extra_deps = _CBP_MISSING_DEP)
            toml = RustCall.parse_cargo_toml(joinpath(host, "Cargo.toml"))
            here = pwd()
            seen, err = withenv("RUSTCALL_OFFLINE" => "1") do
                _cbp_cwd_seen_during(() ->
                    RustCall._build_pyo3_extension_library(host, toml, "cbp_host_461";
                                                           python = "python3"))
            end
            @test seen == Set([here])
            @test err isa RustCall.CargoBuildError
            @test occursin("offline", lowercase(err.stderr))
        end
    end

    @testset "write_bindings_to_file on a crate without a cdylib (items 1, 2, 8)" begin
        mktempdir() do dir
            crate = _cbp_crate(joinpath(dir, "crate"); package = "cbp-rlib-461",
                               lib_name = "cbp_rlib_renamed_461", cdylib = false,
                               body = "#[julia]\npub fn cbp_add461(a: i32, b: i32) -> i32 { a + b }\n")
            for relative in (nothing, "lib")
                out = joinpath(dir, relative === nothing ? "abs" : "rel", "bindings.jl")
                RustCall.write_bindings_to_file(crate, out;
                                                output_module_name = "CbpRlib461",
                                                relative_lib_path = relative)
                code = read(out, String)
                @test occursin("import RustCall.Libdl", code)
                # The library the file names outlives the wrapper project it was
                # built in.
                m = Module(:CbpRlibHost461)
                Core.eval(m, :(using RustCall))
                Base.include(m, out)
                bindings = getfield(m, :CbpRlib461)
                lib_path = getfield(bindings, :_LIB_PATH)
                @test isfile(lib_path)
                @test Base.invokelatest(getfield(bindings, :cbp_add461), Int32(40), Int32(2)) == 42
                RustCall.unload_library(getfield(bindings, :_LIB_NAME); close = true)
            end
        end
    end

    @testset "rebuild_crate builds like @rust_crate (item 4)" begin
        mktempdir() do dir
            crate = _cbp_crate(joinpath(dir, "crate"); package = "cbp-reload-461",
                               lib_name = "cbp_reload_renamed_461",
                               body = "#[julia]\npub fn cbp_one461() -> i32 { 1 }\n")
            elsewhere = joinpath(dir, "ambient-target")
            built = withenv("CARGO_TARGET_DIR" => elsewhere) do
                RustCall.rebuild_crate(crate)
            end
            @test isfile(built)
            # Found under the `[lib] name`, in RustCall's target directory for
            # the crate — not the crate's own `target/`, not the ambient one.
            @test occursin("cbp_reload_renamed_461", basename(built))
            @test startswith(built, RustCall.crate_target_directory(crate))
            @test !isdir(joinpath(crate, "target"))
            @test !isdir(elsewhere)

            # `--offline` under RUSTCALL_OFFLINE.
            offline = _cbp_crate(joinpath(dir, "offline"); package = "cbp_offline_461",
                                 body = "", extra_deps = _CBP_MISSING_DEP)
            err = try
                withenv(() -> RustCall.rebuild_crate(offline), "RUSTCALL_OFFLINE" => "1")
                nothing
            catch e
                e
            end
            @test err isa RustCall.CargoBuildError
            @test err !== nothing && occursin("offline", lowercase(err.stderr))
        end
    end

    @testset "enable_hot_reload_for_crate reaches the @rust_crate module (item 3)" begin
        mktempdir() do dir
            crate = _cbp_crate(joinpath(dir, "crate"); package = "cbp_hot_461",
                               body = "#[julia]\npub fn cbp_value461() -> i32 { 1 }\n")
            bindings = @rust_crate crate name = "CbpHot461"
            name = bindings._LIB_NAME
            @test RustCall._crate_hot_reload_name(crate) == name
            @test name != RustCall.snake_to_pascal("cbp_hot_461")
            try
                state = RustCall.enable_hot_reload_for_crate(crate; poll = true, interval = 60.0)
                @test state.lib_name == name
                RustCall.disable_hot_reload(name)
                delete!(RustCall.HOT_RELOAD_REGISTRY, name)

                state = RustCall.enable_hot_reload_for_crate(bindings, crate;
                                                             poll = true, interval = 60.0)
                @test state.lib_name == name
                @test Base.invokelatest(bindings.cbp_value461) == 1
                write(joinpath(crate, "src", "lib.rs"), """
                    use rustcall_julia_macros::julia;

                    #[julia]
                    pub fn cbp_value461() -> i32 { 2 }
                    """)
                @test RustCall.trigger_reload(name) == true
                # The module's own wrapper now calls the rebuilt library.
                @test Base.invokelatest(bindings.cbp_value461) == 2
            finally
                RustCall.disable_hot_reload(name)
                delete!(RustCall.HOT_RELOAD_REGISTRY, name)
                RustCall.unload_library(name)
            end
        end
    end
end
