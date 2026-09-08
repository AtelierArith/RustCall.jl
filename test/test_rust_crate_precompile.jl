#!/usr/bin/env julia
# `@rust_crate` at the top level of a package that is precompiled (#339).
#
# The generated module used to be evaluated into an anonymous `Module` under
# `Main`, which Julia refuses to serialize into a package's precompile image
# ("Evaluation into the closed module ... breaks incremental compilation"). It
# is now defined inside the module that expands the macro. Three things have
# to hold, and each needs a *separate* process, because a precompile image is
# only ever consumed by a session other than the one that produced it:
#
#   1. a package with `@rust_crate <crate> submodule="Bindings"` at top level,
#      re-exporting through `using .Bindings: ...`, precompiles;
#   2. a fresh session loads it from the image: the module's `__init__` opens
#      the library — RustCall's durable cache copy, not the generation copy
#      the precompiling process made — and functions and structs work;
#   3. after `RustCall.clear_cache()` the image is stale (the library is a
#      precompile dependency through `Base.include_dependency`), so the next
#      `using` re-precompiles the package and builds the crate again, rather
#      than `__init__` failing on a path that is gone.
#
# The subprocesses inherit this process's environment — `RUSTCALL_EXTRACT`
# included — but get a cache directory of their own (`RUSTCALL_CACHE_DIR`), so
# clearing it does not touch the cache the other test workers share. Cargo's
# own output under the fixture's `target/` is shared, so the second build in
# step 3 is a no-op for Cargo: one real crate build.

using Test
using RustCall
using RustToolChain: cargo

const PRECOMP_SAMPLE_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate")
# A crate RustCall has to *wrap*: its `[lib]` is an `rlib`, so the binding goes
# through a generated wrapper project — a temporary directory — rather than
# through the crate's own `cdylib` output.
const PRECOMP_WRAPPED_CRATE = joinpath(@__DIR__, "fixtures", "sample_crate_pyo3_optional")

function _precomp_cargo_available()
    try
        run(pipeline(`$(cargo()) --version`, devnull))
        return true
    catch
        return false
    end
end

@testset "@rust_crate in a precompiled package (#339)" begin
    if !isdir(PRECOMP_SAMPLE_CRATE) || !_precomp_cargo_available()
        @test_skip "cargo and test/fixtures/sample_crate are required"
    else
        root = mktempdir()
        pkg_name = "RustCratePrecomp339"
        pkg_uuid = "3d2f9a71-6b0e-4c2a-9f1d-5e8b7c6a4d39"
        pkgdir_ = joinpath(root, pkg_name)
        cache_dir = joinpath(root, "rustcall-cache")
        mkpath(joinpath(pkgdir_, "src"))
        mkpath(cache_dir)
        write(joinpath(pkgdir_, "Project.toml"), """
        name = "$pkg_name"
        uuid = "$pkg_uuid"
        version = "0.1.0"

        [deps]
        RustCall = "$(Base.PkgId(RustCall).uuid)"
        """)
        # No `Libdl` dependency on purpose: the generated module imports it
        # through RustCall. `LOADED_AT_PRECOMPILE` records whether the library
        # was open while the package's own top level ran — it is not: Julia
        # defers the generated module's `__init__` to load time.
        write(joinpath(pkgdir_, "src", "$pkg_name.jl"), """
        module $pkg_name
        using RustCall
        @rust_crate $(repr(abspath(PRECOMP_SAMPLE_CRATE))) submodule="Bindings"
        using .Bindings: add, Point, distance_from_origin
        export add, Point, distance_from_origin
        const LOADED_AT_PRECOMPILE = Bindings._LIB_GEN[].handle != C_NULL
        end
        """)
        pkgid = Base.PkgId(Base.UUID(pkg_uuid), pkg_name)

        project = pkgdir(RustCall)
        sep = Sys.iswindows() ? ";" : ":"
        function in_subprocess(script::AbstractString)
            withenv("JULIA_LOAD_PATH" => join((project, root, "@stdlib"), sep),
                    "RUSTCALL_CACHE_DIR" => cache_dir,
                    "RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
                # stderr carries the precompilation progress and RustCall's
                # `@info` lines; only stdout is the answer.
                readchomp(pipeline(`$(Base.julia_cmd()) --startup-file=no -e $script`;
                                   stderr = devnull))
            end
        end

        try
            # 1. The first session precompiles the package (a `using` does, as
            #    `Pkg.precompile()` would), and can use it right away.
            out1 = in_subprocess("""
                using $pkg_name
                print(add(Int32(2), Int32(3)), " ", $pkg_name.LOADED_AT_PRECOMPILE, " ",
                      Base.isprecompiled(Base.identify_package("$pkg_name")))
                """)
            @test out1 == "5 false true"

            # 2. A fresh session finds the image valid, loads the library from
            #    the durable cache path through a per-process copy, and both a
            #    function and a struct — a real type of the package, usable
            #    with `isa` — work.
            out2 = in_subprocess("""
                using RustCall, Libdl
                id = Base.identify_package("$pkg_name")
                was_precompiled = Base.isprecompiled(id)
                using $pkg_name
                B = $pkg_name.Bindings
                p = Point(3.0, 4.0)
                loaded = Libdl.dlpath(B._LIB_GEN[].handle)
                print(was_precompiled, " ", add(Int32(2), Int32(3)), " ",
                      distance_from_origin(p), " ", p isa Point, " ",
                      typeof(p) === B.Point, " ",
                      B isa Module, " ", parentmodule(B) === $pkg_name, " ",
                      startswith(B._LIB_PATH, $(repr(cache_dir))), " ",
                      isfile(B._LIB_PATH), " ",
                      realpath(loaded) != realpath(B._LIB_PATH), " ",
                      dirname(realpath(loaded)) == dirname(realpath(B._LIB_PATH)), " ",
                      occursin(".rustcall.", basename(loaded)))
                """)
            @test out2 == "true 5 5.0 true true true true true true true true true"

            # The library is recorded as a precompile dependency of the image,
            # which is what makes step 3 deterministic.
            cachefiles = Base.find_all_in_cache_path(pkgid)
            @test !isempty(cachefiles)
            if !isempty(cachefiles)
                # `parse_cache_header` returns `(modules, (includes, srcfiles,
                # requires), ...)`; the include_dependency records are in
                # `includes`.
                includes = Base.parse_cache_header(first(cachefiles))[2][1]
                @test any(inc -> startswith(inc.filename, cache_dir), includes)
            end

            # 3. Clearing RustCall's cache removes the library. The image is
            #    now stale — not broken — so the next `using` re-precompiles
            #    the package, `@rust_crate` builds the crate again, and calls
            #    work.
            out3 = in_subprocess("""
                using RustCall
                RustCall.clear_cache()
                id = Base.identify_package("$pkg_name")
                stale = !Base.isprecompiled(id)
                using $pkg_name
                B = $pkg_name.Bindings
                print(stale, " ", add(Int32(4), Int32(5)), " ", isfile(B._LIB_PATH), " ",
                      Base.isprecompiled(id))
                """)
            @test out3 == "true 9 true true"
        finally
            # The image lives in the shared depot, in a directory named after
            # this package alone: remove it, then the subprocesses' cache
            # directory together with the temporary package.
            for dir in unique(dirname.(Base.find_all_in_cache_path(pkgid)))
                rm(dir; recursive = true, force = true)
            end
            rm(root; recursive = true, force = true)
        end
    end
end

# The path the generated module carries must be one that exists for as long as
# the module does. With caching on that is RustCall's cache copy; with
# `cache = false` on a crate that needs a wrapper crate it used to be a file
# inside the wrapper project, which `cleanup_cargo_project` deletes as soon as
# the build returns — so `__init__` opened a path that was already gone
# ("could not load library ... /T/rustcall_wrapper_XXXXXX/target/release/...").
@testset "cache = false never names a deleted build tree (#339)" begin
    if !isdir(PRECOMP_WRAPPED_CRATE) || !_precomp_cargo_available()
        @test_skip "cargo and test/fixtures/sample_crate_pyo3_optional are required"
    else
        # Before the fix this line itself threw: the module's `__init__` ran
        # `dlopen` on a file the wrapper project's cleanup had already taken
        # with it.
        bindings = @rust_crate PRECOMP_WRAPPED_CRATE cache=false
        generated = bindings.module_ref
        @test isfile(generated._LIB_PATH)
        # The library is open, so the path named a real file at load time as
        # well as now.
        @test generated._LIB_GEN[].handle != C_NULL
        # This crate exposes nothing without its `python` feature, so there is
        # no binding to call: the library and its load are the whole claim.
        @test isempty(RustCall.scan_crate(PRECOMP_WRAPPED_CRATE).julia_functions)
    end
end

# `const X = @rust_crate <crate> name="X"` is the form the macro's docstring has
# always shown. It must keep working, and that is why `name=` names the
# generated module without defining it in the caller: a version that defined
# `X` and then bound the returned `CrateBindings` over it produced a package
# whose precompile image **segfaulted** on load (signal 11), not merely a
# redefinition error (#339 review).
@testset "const X = @rust_crate ... name=\"X\" still loads (#339 review)" begin
    if !isdir(PRECOMP_SAMPLE_CRATE) || !_precomp_cargo_available()
        @test_skip "cargo and test/fixtures/sample_crate are required"
    else
        # In-process first: the name is not defined here, only the value.
        bindings = @rust_crate PRECOMP_SAMPLE_CRATE name="PrecompSameName"
        @test bindings isa RustCall.CrateBindings
        @test !isdefined(@__MODULE__, :PrecompSameName)
        @test nameof(bindings.module_ref) === :PrecompSameName

        # And in a package that is precompiled and then loaded in a fresh
        # session, which is where the crash happened.
        root = mktempdir()
        pkg_name = "RustCrateSameName339"
        pkg_uuid = "5c7e1b90-2d43-4f18-9a06-3b8e7d24c1af"
        pkgdir_ = joinpath(root, pkg_name)
        cache_dir = joinpath(root, "rustcall-cache")
        mkpath(joinpath(pkgdir_, "src"))
        mkpath(cache_dir)
        write(joinpath(pkgdir_, "Project.toml"), """
        name = "$pkg_name"
        uuid = "$pkg_uuid"
        version = "0.1.0"

        [deps]
        RustCall = "$(Base.PkgId(RustCall).uuid)"
        """)
        write(joinpath(pkgdir_, "src", "$pkg_name.jl"), """
        module $pkg_name
        using RustCall
        const MyBindings = @rust_crate $(repr(abspath(PRECOMP_SAMPLE_CRATE))) name="MyBindings"
        end
        """)
        pkgid = Base.PkgId(Base.UUID(pkg_uuid), pkg_name)
        sep = Sys.iswindows() ? ";" : ":"
        try
            out = withenv("JULIA_LOAD_PATH" => join((pkgdir(RustCall), root, "@stdlib"), sep),
                          "RUSTCALL_CACHE_DIR" => cache_dir,
                          "RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
                readchomp(pipeline(`$(Base.julia_cmd()) --startup-file=no -e """
                    using $pkg_name
                    print($pkg_name.MyBindings.add(Int32(1), Int32(2)))
                    """`; stderr = devnull))
            end
            @test out == "3"
        finally
            for dir in unique(dirname.(Base.find_all_in_cache_path(pkgid)))
                rm(dir; recursive = true, force = true)
            end
            rm(root; recursive = true, force = true)
        end
    end
end

# Editing the crate must invalidate the package's precompile image. It does not
# follow from tracking the library: the library is content-addressed, so a new
# build lands at a *different* cache path and leaves the old file untouched —
# nothing Julia tracks would have moved, and the package would go on calling the
# previous build. The module therefore declares the crate's own input files, the
# very set its artifact identity is computed from (#339 review).
@testset "Editing the crate invalidates the package image (#339 review)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        root = mktempdir()
        crate = joinpath(root, "edited_crate")
        mkpath(joinpath(crate, "src"))
        macros = replace(joinpath(dirname(@__DIR__), "deps", "juliacall_macros"), "\\" => "/")
        write(joinpath(crate, "Cargo.toml"), """
            [package]
            name = "edited_crate"
            version = "0.1.0"
            edition = "2021"

            [lib]
            crate-type = ["cdylib"]

            [dependencies]
            juliacall_macros = { path = "$macros" }
            """)
        source(offset) = """
            use juliacall_macros::julia;
            #[julia]
            pub fn total(a: i32, b: i32) -> i32 { a + b + $offset }
            """
        write(joinpath(crate, "src", "lib.rs"), source(0))

        pkg_name = "RustCrateEdited339"
        pkg_uuid = "9f3c1d70-4a52-4b86-9d13-7e2c5a8b6f04"
        pkgdir_ = joinpath(root, pkg_name)
        cache_dir = joinpath(root, "rustcall-cache")
        mkpath(joinpath(pkgdir_, "src"))
        mkpath(cache_dir)
        write(joinpath(pkgdir_, "Project.toml"), """
        name = "$pkg_name"
        uuid = "$pkg_uuid"
        version = "0.1.0"

        [deps]
        RustCall = "$(Base.PkgId(RustCall).uuid)"
        """)
        write(joinpath(pkgdir_, "src", "$pkg_name.jl"), """
        module $pkg_name
        using RustCall
        @rust_crate $(repr(abspath(crate))) submodule="Bindings"
        using .Bindings: total
        export total
        end
        """)
        pkgid = Base.PkgId(Base.UUID(pkg_uuid), pkg_name)
        sep = Sys.iswindows() ? ";" : ":"
        run_pkg(script) = withenv("JULIA_LOAD_PATH" => join((pkgdir(RustCall), root, "@stdlib"), sep),
                                  "RUSTCALL_CACHE_DIR" => cache_dir,
                                  "RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
            readchomp(pipeline(`$(Base.julia_cmd()) --startup-file=no -e $script`; stderr = devnull))
        end

        # `Base.isprecompiled` needs the package's *source* on the load path,
        # which only the subprocesses have — asked here it raises "Cannot
        # locate source". So the staleness question is asked inside a session
        # that can see the package, before it loads it.
        stale_then_call = """
            id = Base.identify_package("$pkg_name")
            stale = !Base.isprecompiled(id)
            using $pkg_name
            print(stale, " ", total(Int32(2), Int32(3)), " ", Base.isprecompiled(id))
            """

        try
            @test run_pkg(stale_then_call) == "true 5 true"

            # The crate's source files are among the image's dependencies.
            cachefiles = Base.find_all_in_cache_path(pkgid)
            @test !isempty(cachefiles)
            if !isempty(cachefiles)
                includes = Base.parse_cache_header(first(cachefiles))[2][1]
                @test any(inc -> inc.filename == joinpath(crate, "src", "lib.rs"), includes)
            end

            # Nothing changed: the image stays valid and the crate is not
            # rebuilt.
            @test run_pkg(stale_then_call) == "false 5 true"

            # Edit the crate. `include_dependency` compares mtimes, and a build
            # can be fast enough to land in the same second.
            sleep(1.1)
            write(joinpath(crate, "src", "lib.rs"), source(100))

            # The next session finds the image stale, re-precompiles, rebuilds
            # the crate, and calls the new code.
            @test run_pkg(stale_then_call) == "true 105 true"
        finally
            for dir in unique(dirname.(Base.find_all_in_cache_path(pkgid)))
                rm(dir; recursive = true, force = true)
            end
            rm(root; recursive = true, force = true)
        end
    end
end

# `.cargo/config.toml` decides the flags a build runs under and is part of the
# artifact key (`_cargo_config_digest`), so an edit to it changes the binary
# without touching a file of the crate. It has to be tracked as well, or the
# package's image stays valid over a build it no longer describes (#339 review).
@testset "Cargo configuration files are precompile dependencies (#339 review)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        root = mktempdir()
        crate = joinpath(root, "configured_crate")
        mkpath(joinpath(crate, "src", ""))
        mkpath(joinpath(crate, ".cargo"))
        config = joinpath(crate, ".cargo", "config.toml")
        write(config, "# empty\n")
        macros = replace(joinpath(dirname(@__DIR__), "deps", "juliacall_macros"), "\\" => "/")
        write(joinpath(crate, "Cargo.toml"), """
            [package]
            name = "configured_crate"
            version = "0.1.0"
            edition = "2021"

            [lib]
            crate-type = ["cdylib"]

            [dependencies]
            juliacall_macros = { path = "$macros" }
            """)
        write(joinpath(crate, "src", "lib.rs"), """
            use juliacall_macros::julia;
            #[julia]
            pub fn one() -> i32 { 1 }
            """)
        try
            # The list the generated module declares, and the digest that
            # decides the artifact key, must name the same file.
            deps = RustCall._crate_precompile_dependencies(crate)
            @test config in deps
            @test joinpath(crate, "src", "lib.rs") in deps
            @test config in RustCall._cargo_config_files(ENV; dir = crate)
        finally
            rm(root; recursive = true, force = true)
        end
    end
end
