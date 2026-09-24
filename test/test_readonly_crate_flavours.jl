using Test
using RustCall

# Every `@rust_crate` flavour builds a crate from a read-only tree (#486).
#
# A package installed under a depot is read-only, so no flavour may write into
# the crate it binds: the direct `cdylib` build, a hot reload's rebuild, the
# `pyo3_host = true` extension build and the PyO3 wrapper (with its probes) all
# put their Cargo output under `RustCall.crate_target_directory(crate, flavour)`
# in RustCall's cache. Each testset below copies a fixture, makes the copy
# read-only, binds it with one flavour, and checks that the binding works and
# that nothing appeared in the crate. What a read-only crate must ship is its
# `Cargo.lock`: no flavour passes `--locked`, and Cargo writes that file beside
# the manifest when it is missing or stale (docs/src/integration_guide.md).

include(joinpath(@__DIR__, "pyo3_wrapper_helpers.jl"))

if Base.find_package("PythonCall") !== nothing
    @eval using PythonCall
end

const _RO_FIXTURES = joinpath(@__DIR__, "fixtures")

_ro_cargo_ok() = try
    success(`$(RustCall.cargo()) --version`)
catch
    false
end

# A copy of a fixture crate. Its committed `Cargo.lock` comes along; a path
# dependency on `rustcall_julia_macros` is made absolute so the copy builds
# from anywhere.
function _ro_copy_crate(fixture, root)
    src = joinpath(_RO_FIXTURES, fixture)
    crate = joinpath(root, fixture)
    cp(src, crate)
    rm(joinpath(crate, "target"); recursive = true, force = true)
    manifest = joinpath(crate, "Cargo.toml")
    text = replace(read(manifest, String),
                   "\"../../../deps/rustcall_julia_macros\"" =>
                   repr(RustCall.rustcall_runtime_crate_path()))
    write(manifest, text)
    @assert isfile(joinpath(crate, "Cargo.lock"))
    return crate
end

_ro_listing(dir) = sort!([relpath(joinpath(r, f), dir) for (r, _, fs) in walkdir(dir) for f in fs])

function _ro_set_writable!(dir, writable::Bool)
    for (r, ds, fs) in walkdir(dir; topdown = false)
        for f in fs
            chmod(joinpath(r, f), writable ? 0o644 : 0o444)
        end
        for d in ds
            chmod(joinpath(r, d), writable ? 0o755 : 0o555)
        end
    end
    chmod(dir, writable ? 0o755 : 0o555)
    return nothing
end

function _ro_is_read_only(dir)
    probe = joinpath(dir, "probe486")
    try
        touch(probe)
        rm(probe; force = true)
        return false
    catch
        return true
    end
end

# Runs `f(crate)` against a read-only copy of `fixture`, then checks that the
# crate's file listing is unchanged and that it has no `target/`. Permissions
# are restored in `finally`, so the temporary tree can be removed. Where the
# copy stays writable (root, or Windows, whose directory attributes do not stop
# file creation) the listing check still holds.
function _ro_with_read_only_crate(f, fixture, root; prepare = identity)
    crate = _ro_copy_crate(fixture, root)
    prepare(crate)
    before = _ro_listing(crate)
    _ro_set_writable!(crate, false)
    _ro_is_read_only(crate) ||
        @info "The crate copy is still writable here (root, or Windows); checking only that nothing is written"
    try
        f(crate)
        @test _ro_listing(crate) == before
        @test !isdir(joinpath(crate, "target"))
    finally
        _ro_set_writable!(crate, true)
    end
end

_ro_julia(script, env...) = withenv(env..., "RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
    readchomp(`$(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(RustCall)) -e $script`)
end

@testset "every flavour has its own target directory under the crate's (#486)" begin
    mktempdir() do root
        withenv("RUSTCALL_CACHE_DIR" => joinpath(root, "cache")) do
            crate = mkpath(joinpath(root, "crate", "src"))
            crate = dirname(crate)
            write(joinpath(crate, "Cargo.toml"), "[package]\nname = \"c486\"\nversion = \"0.1.0\"\n")
            write(joinpath(crate, "src", "lib.rs"), "")
            base = RustCall.crate_target_directory(crate)
            @test base == RustCall.crate_target_directory(crate, :direct)
            @test startswith(base, RustCall.get_cargo_cache_dir())
            flavours = (:direct, :pyo3_host, :pyo3_wrapper)
            dirs = [RustCall.crate_target_directory(crate, f) for f in flavours]
            @test allunique(dirs)
            # One `<base>` per crate, so `cleanup_old_cache` ages every
            # flavour's build of one crate together.
            @test all(d -> startswith(d, base), dirs)
            @test all(d -> !startswith(d, crate), dirs)
            @test_throws ArgumentError RustCall.crate_target_directory(crate, :nope)

            # Windows' 260-character path limit (#486). The cache root there is
            # about 100 characters, and Cargo nests up to about 90 more below a
            # target directory for a dependency's build script
            # (`release/build/target-lexicon-<16>/build_script_build-<16>.exe`),
            # so what RustCall adds between the Cargo cache and Cargo's own
            # layout must stay small. The full 64-hex key did not: a
            # `pyo3_host` build failed with LNK1104 at 262 characters.
            cargo_cache = RustCall.get_cargo_cache_dir()
            for d in dirs
                @test length(relpath(d, cargo_cache)) <= 40
            end
            # So must the generated wrapper's package name, which Cargo puts
            # in `build/<package>-<16>/` for the wrapper's own build script.
            @test occursin("with_short_name(target, key; prefix = \"rustcall_wrapper_\")",
                           read(joinpath(pkgdir(RustCall), "src", "pyo3.jl"), String))
            @test length(RustCall.short_name("f"^64; prefix = "rustcall_wrapper_")) ==
                  length("rustcall_wrapper_") + RustCall.ARTIFACT_SHORT_ID_LEN

            # Using a flavour's directory refreshes the crate's one stamp.
            dir = RustCall._crate_target!(crate, :pyo3_host)
            @test isdir(dir)
            @test isfile(joinpath(base, RustCall.TARGET_LAST_USED_STAMP))

            # The PyO3 wrapper's projects and its probe build there too.
            project, lease = RustCall._wrapper_shaped_project(crate, "rustcall-pyo3-test")
            try
                @test startswith(project, RustCall.crate_target_directory(crate, :pyo3_wrapper))
            finally
                RustCall._remove_shaped_project(project, lease)
            end
            env = RustCall._wrapper_probe_env(Dict{String, String}(), crate, true, "")
            @test env["CARGO_TARGET_DIR"] == RustCall.crate_target_directory(crate, :pyo3_wrapper)
            @test !isdir(joinpath(crate, "target"))
        end
    end
end

@testset "a cdylib crate binds and hot reloads from a read-only tree (#486)" begin
    if !RustCall.check_rustc_available() || !_ro_cargo_ok()
        @test_skip "rustc and cargo are required"
    else
        mktempdir() do root
            # CRLF line endings, as a Windows checkout with `core.autocrlf`
            # gives the fixture: the edit below must not depend on them (the
            # first Windows run matched a `\n`-only pattern, edited nothing,
            # and reloaded the old source).
            crlf!(crate) = (lib = joinpath(crate, "src", "lib.rs");
                            write(lib, replace(replace(read(lib, String), "\r\n" => "\n"),
                                               "\n" => "\r\n")))
            _ro_with_read_only_crate("sample_crate", root; prepare = crlf!) do crate
                lib_rs = joinpath(crate, "src", "lib.rs")
                original = read(lib_rs, String)
                @test occursin("\r\n", original)
                edited = replace(original,
                                 r"(fn add\(a: i32, b: i32\) -> i32 \{\r?\n\s*a \+ b)(\r?\n\})" =>
                                 s"\1 + 100\2"; count = 1)
                @test edited != original
                # Outside the crate; the child copies it over `lib.rs`.
                edited_path = joinpath(root, "edited_lib.rs")
                write(edited_path, edited)
                # A fresh process with a cold cache: the direct build, its cfg
                # probe, and a hot reload's rescan and rebuild all run. The
                # source is edited in place between the two builds — the file is
                # made writable for that one write and read-only again, the way
                # an editor would save into a tree whose build must not write.
                script = """
                    using RustCall
                    crate = $(repr(crate))
                    lib_rs = $(repr(lib_rs))
                    bindings = @rust_crate crate name="ReadOnly486"
                    first = Base.invokelatest(bindings.add, Int32(2), Int32(3))
                    # A short interval: `disable_hot_reload` waits for the
                    # watcher to notice it has been stopped.
                    state = RustCall.enable_hot_reload_for_crate(bindings; interval = 0.5)
                    chmod(lib_rs, 0o644)
                    write(lib_rs, read($(repr(edited_path)), String))
                    chmod(lib_rs, 0o444)
                    reloaded = RustCall.trigger_reload(state.lib_name)
                    second = Base.invokelatest(bindings.add, Int32(2), Int32(3))
                    RustCall.disable_hot_reload(state.lib_name)
                    print(first, " ", reloaded, " ", second, " ",
                          isdir(RustCall.crate_target_directory(crate)))
                    """
                out = _ro_julia(script, "RUSTCALL_CACHE_DIR" => joinpath(root, "cache"))
                @test out == "5 true 105 true"
                @test occursin("a + b + 100", read(lib_rs, String))
            end
        end
    end
end

# The interpreter `pyo3_host` builds against. The build itself needs only an
# executable (it runs it as a subprocess); PythonCall is needed for the import.
function _ro_host_python()
    RustCall.pyo3_host_available() && return PythonCall.python_executable_path()
    configured = get(ENV, "PYO3_PYTHON", "")
    isempty(configured) || return configured
    for name in ("python3", "python")
        found = Sys.which(name)
        found === nothing || return found
    end
    return nothing
end

@testset "a pyo3_host extension builds from a read-only tree (#486)" begin
    python = _ro_host_python()
    if !RustCall.check_rustc_available() || !_ro_cargo_ok()
        @test_skip "rustc and cargo are required"
    elseif python === nothing
        @test_skip "the pyo3_host build needs a Python interpreter to configure pyo3 for"
    else
        mktempdir() do root
            withenv("RUSTCALL_CACHE_DIR" => joinpath(root, "cache")) do
                _ro_with_read_only_crate("sample_crate_pyo3_host", root) do crate
                    # The interpreter-free half: the build and its cache entry.
                    # A hard failure once Python and Cargo are here.
                    artifact = RustCall.build_pyo3_extension(crate; python = python)
                    @test isfile(artifact.lib_path)
                    @test startswith(artifact.lib_path, RustCall.get_cache_dir())
                    @test isdir(RustCall.crate_target_directory(crate, :pyo3_host))
                    if RustCall.pyo3_host_available()
                        # With PythonCall loaded, the import of the same
                        # artifact, and the `@rust_crate pyo3_host = true`
                        # binding, which reuses that build.
                        module_ = RustCall.pyo3_host_import(artifact)
                        @test pyconvert(Int, module_.add(2, 3)) == 5
                        Host = @rust_crate crate pyo3_host = true
                        @test Host.add(Int32(2), Int32(3)) == 5
                    else
                        @test_skip "importing the read-only-built extension needs PythonCall; `using PythonCall` enables RustCallPyO3HostExt"
                    end
                end
            end
        end
    end
end

@testset "a PyO3 wrapper and its probes run from a read-only tree (#486)" begin
    if !RustCall.check_rustc_available() || !_ro_cargo_ok()
        @test_skip "rustc and cargo are required"
    else
        mktempdir() do root
            withenv("RUSTCALL_CACHE_DIR" => joinpath(root, "cache")) do
                _ro_with_read_only_crate("sample_crate_pyo3_optional", root) do crate
                    # The cfg probe and the feature resolution run in generated
                    # projects under the wrapper's target directory; neither
                    # writes into the crate, and both still answer.
                    plan = RustCall.pyo3_link_plan(crate)
                    @test plan.resolved
                    @test plan.mode === :python_free
                    @test occursin("target_os=", plan.cfg_text)
                    plan_on = RustCall.pyo3_link_plan(crate; features = ["python"],
                                                      default_features = false)
                    @test plan_on.resolved
                    @test isdir(RustCall.crate_target_directory(crate, :pyo3_wrapper))
                    # The wrapper build itself, where a Python can be linked.
                    wrapper = _link_libpython_wrapper(crate; features = ["python"],
                                                      default_features = false,
                                                      cache_enabled = false)
                    if wrapper === nothing
                        @test_skip "no linkable Python here: the read-only PyO3 wrapper cannot be built"
                    else
                        @test isfile(wrapper.lib_path)
                        @test "add" in Set(f.name for f in wrapper.info.julia_functions)
                    end
                end
            end
        end
    end
end
