using Test
using RustCall

# A crate that already declares `cdylib` is built in place by `@rust_crate`
# (`build_crate_directly`), and its build configuration is probed with
# `cargo rustc -- --print cfg` in the same directory. Neither may write into
# the crate: a package installed under a depot is read-only, and a crate's
# `target/` is not somewhere RustCall's cache can carry (#445). Both use
# `RustCall.crate_target_directory(crate)`, a directory under RustCall's cache.

const DBT_FIXTURE = joinpath(@__DIR__, "fixtures", "sample_crate")

_dbt_cargo_ok() = try
    success(`$(RustCall.cargo()) --version`)
catch
    false
end

# A copy of the fixture whose `rustcall_julia_macros` path dependency is
# absolute, so it builds from anywhere. The fixture's committed `Cargo.lock`
# comes along: a lockfile does not record path dependencies' locations.
function _dbt_copy_crate(root)
    crate = joinpath(root, "crate445")
    mkpath(joinpath(crate, "src"))
    cp(joinpath(DBT_FIXTURE, "src", "lib.rs"), joinpath(crate, "src", "lib.rs"))
    cp(joinpath(DBT_FIXTURE, "Cargo.lock"), joinpath(crate, "Cargo.lock"))
    manifest = replace(read(joinpath(DBT_FIXTURE, "Cargo.toml"), String),
                       "\"../../../deps/rustcall_julia_macros\"" =>
                       repr(RustCall.rustcall_runtime_crate_path()))
    write(joinpath(crate, "Cargo.toml"), manifest)
    return crate
end

_dbt_listing(dir) = sort!([relpath(joinpath(r, f), dir) for (r, _, fs) in walkdir(dir) for f in fs])

function _dbt_set_writable!(dir, writable::Bool)
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

function _dbt_is_read_only(dir)
    probe = joinpath(dir, "probe445")
    try
        touch(probe)
        rm(probe; force = true)
        return false
    catch
        return true
    end
end

@testset "crate_target_directory (#445)" begin
    mktempdir() do root
        withenv("RUSTCALL_CACHE_DIR" => joinpath(root, "cache")) do
            a = mkpath(joinpath(root, "a"))
            b = mkpath(joinpath(root, "b"))
            ta = RustCall.crate_target_directory(a)
            # Under RustCall's cache, never under the crate.
            @test startswith(ta, RustCall.get_cache_dir())
            @test !startswith(ta, a)
            # Stable for one crate, however its path is spelled...
            @test RustCall.crate_target_directory(a) == ta
            @test RustCall.crate_target_directory(joinpath(a, ".")) == ta
            if !Sys.iswindows()
                link = joinpath(root, "link")
                symlink(a, link)
                @test RustCall.crate_target_directory(link) == ta
            end
            # ...and distinct between crates: two crates with the same package
            # name would otherwise overwrite each other's `target/release/lib*`.
            @test RustCall.crate_target_directory(b) != ta
        end
    end
end

@testset "a direct @rust_crate build writes nothing into the crate (#445)" begin
    if !RustCall.check_rustc_available() || !_dbt_cargo_ok()
        @test_skip "rustc and cargo are required"
    else
        mktempdir() do root
            crate = _dbt_copy_crate(root)
            before = _dbt_listing(crate)
            _dbt_set_writable!(crate, false)
            read_only = _dbt_is_read_only(crate)
            read_only || @info "The crate copy is still writable here (root, or Windows); checking only that nothing is written"
            try
                # A fresh process with a cold cache: nothing may short-circuit
                # the probe or the build.
                script = """
                    using RustCall
                    bindings = @rust_crate $(repr(crate)) name="DirectBuild445"
                    print(Base.invokelatest(bindings.add, Int32(2), Int32(3)), " ",
                          isdir(RustCall.crate_target_directory($(repr(crate)))))
                    """
                out = withenv("RUSTCALL_CACHE_DIR" => joinpath(root, "cache"),
                              "RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
                    readchomp(`$(Base.julia_cmd()) --startup-file=no --project=$(pkgdir(RustCall)) -e $script`)
                end
                @test out == "5 true"
                @test _dbt_listing(crate) == before
                @test !isdir(joinpath(crate, "target"))
            finally
                _dbt_set_writable!(crate, true)
            end
        end
    end
end

@testset "the cfg probe of a cdylib crate writes nothing into the crate (#445)" begin
    if !_dbt_cargo_ok()
        @test_skip "cargo is required"
    else
        mktempdir() do root
            crate = _dbt_copy_crate(root)
            before = _dbt_listing(crate)
            withenv("RUSTCALL_CACHE_DIR" => joinpath(root, "cache")) do
                cfg = RustCall._crate_build_cfg_text(crate)
                @test occursin("target_os=", cfg)
            end
            @test _dbt_listing(crate) == before
        end
    end
end

