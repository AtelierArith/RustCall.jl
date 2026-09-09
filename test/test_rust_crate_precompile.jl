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
        # Julia's compiled-cache directory is keyed by package name. A
        # concurrent invocation must not share the directory our cleanup
        # removes, even though each invocation already has a private source.
        pkg_name = "RustCratePrecomp339_$(basename(root))"
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
                                   stderr = stderr))
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

            @testset "precompiled crate views restore process-owned runtime state (#251)" begin
                owned = in_subprocess("""
                    using RustCall, $pkg_name
                    B = $pkg_name.Bindings
                    print(B._LIB_GEN isa RustCall.StateView, " ",
                          B._SYMBOLS isa RustCall.StateView, " ",
                          B._LIB_GEN.owner === B._SYMBOLS.owner === B, " ",
                          haskey(RustCall.MODULE_STATES, B), " ",
                          B._PRELOAD_LIBRARIES isa Tuple && B._CRATE_INPUTS isa Tuple &&
                          B._BUILD_ENV isa Tuple, " ", add(Int32(2), Int32(3)))
                    """)
                @test owned == "true true true true true 5"
            end

            @testset "a precompiled package refuses changed non-file build inputs (#355)" begin
                for key in ("PYO3_PYTHON", "RUSTFLAGS")
                    replacement = key == "PYO3_PYTHON" ? joinpath(root, "different-python") :
                        (get(ENV, key, "") == "-C opt-level=1" ? "-C opt-level=2" : "-C opt-level=1")
                    withenv(key => replacement) do
                        changed = in_subprocess("""
                            using RustCall
                            id = Base.identify_package("$pkg_name")
                            print(Base.isprecompiled(id), " ")
                            try
                                Base.require(id)
                                print("loaded stale library")
                            catch err
                                print(err isa InitError, " ",
                                      occursin($(repr(key)), sprint(showerror, err)))
                            end
                            """)
                        # The existing image is valid according to Julia, but
                        # __init__ refuses its stale Rust build environment.
                        @test changed == "true true true"
                    end
                end
                @test in_subprocess("using $pkg_name; print(add(Int32(2), Int32(3)))") == "5"
            end

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
        # And the copy outlives this process: not a `mktempdir()` that is
        # cleaned at exit, but a directory under the Cargo cache that only
        # `clear_cache()` removes — a package precompiled with `cache = false`
        # is loaded by a process other than the one that made the copy.
        @test startswith(generated._LIB_PATH, RustCall.get_cargo_cache_dir())
        @test occursin("uncached_", generated._LIB_PATH)
        # The library is open, so the path named a real file at load time as
        # well as now.
        @test generated._LIB_GEN[].handle != C_NULL
        # This crate exposes nothing without its `python` feature, so there is
        # no binding to call: the library and its load are the whole claim.
        @test isempty(RustCall.scan_crate(PRECOMP_WRAPPED_CRATE).julia_functions)
    end
end

# A run-time `@rust_crate` — a function called in a loop, a REPL line evaluated
# again — must not grow the caller: a child module defined in the caller can
# never be removed, so outside precompilation the module stays under an
# anonymous `Main`-rooted module, as it always did (#339 review).
@testset "A run-time @rust_crate leaves nothing in the caller (#339 review)" begin
    if !isdir(PRECOMP_SAMPLE_CRATE) || !_precomp_cargo_available()
        @test_skip "cargo and test/fixtures/sample_crate are required"
    else
        load_twice() = (@rust_crate PRECOMP_SAMPLE_CRATE), (@rust_crate PRECOMP_SAMPLE_CRATE)
        before = Set(Base.invokelatest(names, @__MODULE__; all = true))
        a, b = load_twice()
        @test a.add(Int32(1), Int32(1)) == 2 && b.add(Int32(2), Int32(2)) == 4
        @test Set(Base.invokelatest(names, @__MODULE__; all = true)) == before
        @test parentmodule(parentmodule(a.module_ref)) === Main
        @test a.module_ref !== b.module_ref
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
        pkg_name = "RustCrateSameName339_$(basename(root))"
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
                    """`; stderr = stderr))
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

        pkg_name = "RustCrateEdited339_$(basename(root))"
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
            readchomp(pipeline(`$(Base.julia_cmd()) --startup-file=no -e $script`; stderr = stderr))
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

            # A file *appearing* changes the artifact — `crate_content_digest`
            # hashes the file list — while touching none of the files the image
            # already knew. The directories are in the dependency list for
            # exactly this (#339 review).
            sleep(1.1)
            write(joinpath(crate, "src", "extra.rs"), "// not referenced\n")
            @test run_pkg(stale_then_call) == "true 105 true"

            # And the file it added is itself tracked from then on.
            sleep(1.1)
            rm(joinpath(crate, "src", "extra.rs"))
            @test run_pkg(stale_then_call) == "true 105 true"

            # A directory that held no input at all is tracked too: the first
            # file appearing in an empty `assets/` changes the artifact, moves
            # no file, and leaves the parent's entry list alone because the
            # directory was already there (#339 review).
            mkpath(joinpath(crate, "assets"))
            sleep(1.1)
            @test run_pkg(stale_then_call) == "true 105 true"   # `assets/` itself is new
            sleep(1.1)
            write(joinpath(crate, "assets", "table.csv"), "1,2\n")
            @test run_pkg(stale_then_call) == "true 105 true"   # a file inside it is new
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
# A `features = [...]` build can activate an optional `path` dependency that the
# default `cargo tree` graph never lists; every local dependency a manifest
# declares is tracked, optional or not (#339 review).
@testset "Optional path dependencies are precompile dependencies (#339 review)" begin
    mktempdir() do root
        mkpath(joinpath(root, "main", "src")); mkpath(joinpath(root, "extra", "src"))
        write(joinpath(root, "extra", "Cargo.toml"), """
            [package]
            name = "extra"
            version = "0.1.0"
            edition = "2021"
            """)
        write(joinpath(root, "extra", "src", "lib.rs"), "pub fn e() -> i32 { 1 }\n")
        write(joinpath(root, "main", "Cargo.toml"), """
            [package]
            name = "main"
            version = "0.1.0"
            edition = "2021"

            [features]
            with_extra = ["dep:extra"]

            [dependencies]
            extra = { path = "../extra", optional = true }
            """)
        write(joinpath(root, "main", "src", "lib.rs"), "pub fn m() -> i32 { 1 }\n")
        deps = RustCall._crate_precompile_dependencies(joinpath(root, "main"))
        @test joinpath(root, "extra", "src", "lib.rs") in deps
        @test joinpath(root, "extra", "Cargo.toml") in deps
        # The crate's *parent* is not an input: an unrelated sibling appearing
        # in the checkout must not invalidate the image (#339 review).
        @test normpath(root) ∉ normpath.(deps)

        # The same crate is in the artifact key: an edit to it changes the
        # digest, so a rebuild cannot find the old library under the old key.
        _, dirs = RustCall.local_path_dependency_dirs(joinpath(root, "main"))
        @test any(d -> RustCall._canonical_dir(d) == RustCall._canonical_dir(joinpath(root, "extra")), dirs)
        before = RustCall.artifact_path_dependency_digest(joinpath(root, "main"))
        write(joinpath(root, "extra", "src", "lib.rs"), "pub fn e() -> i32 { 2 }\n")
        @test RustCall.artifact_path_dependency_digest(joinpath(root, "main")) != before

        # And a crate the optional one declares in turn is followed as well.
        mkpath(joinpath(root, "deeper", "src"))
        write(joinpath(root, "deeper", "Cargo.toml"), """
            [package]
            name = "deeper"
            version = "0.1.0"
            edition = "2021"
            """)
        write(joinpath(root, "deeper", "src", "lib.rs"), "pub fn d() -> i32 { 1 }\n")
        write(joinpath(root, "extra", "Cargo.toml"), """
            [package]
            name = "extra"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            deeper = { path = "../deeper", optional = true }
            """)
        @test joinpath(root, "deeper", "src", "lib.rs") in
              RustCall._crate_precompile_dependencies(joinpath(root, "main"))
    end
end

# `[patch.crates-io] extra = { path = "../local" }` swaps a registry dependency
# for a local crate. The dependency table still says `version = "..."`, so
# harvesting it never names the directory, and when the dependency is optional
# the default `cargo tree` graph omits it as well: an edit to the local crate
# changed neither the artifact key nor the declared inputs, and a
# feature-enabled rebuild found the old library (#339 review). Patch tables are
# harvested too — the crate's own and, for a workspace member, the root's,
# which is the one Cargo honours.
@testset "Patched-in local crates are precompile dependencies (#339 review)" begin
    mktempdir() do root
        mkpath(joinpath(root, "main", "src")); mkpath(joinpath(root, "local_extra", "src"))
        write(joinpath(root, "local_extra", "Cargo.toml"), """
            [package]
            name = "extra"
            version = "0.1.0"
            edition = "2021"
            """)
        write(joinpath(root, "local_extra", "src", "lib.rs"), "pub fn e() -> i32 { 1 }\n")
        write(joinpath(root, "main", "Cargo.toml"), """
            [package]
            name = "main"
            version = "0.1.0"
            edition = "2021"

            [features]
            with_extra = ["dep:extra"]

            [dependencies]
            extra = { version = "0.1", optional = true }

            [patch.crates-io]
            extra = { path = "../local_extra" }
            """)
        write(joinpath(root, "main", "src", "lib.rs"), "pub fn m() -> i32 { 1 }\n")
        @test any(p -> RustCall._canonical_dir(p) == RustCall._canonical_dir(joinpath(root, "local_extra")),
                  RustCall._declared_path_dependencies(joinpath(root, "main", "Cargo.toml")))
        deps = RustCall._crate_precompile_dependencies(joinpath(root, "main"))
        @test joinpath(root, "local_extra", "src", "lib.rs") in deps
        @test joinpath(root, "local_extra", "Cargo.toml") in deps
        _, dirs = RustCall.local_path_dependency_dirs(joinpath(root, "main"))
        @test any(d -> RustCall._canonical_dir(d) == RustCall._canonical_dir(joinpath(root, "local_extra")), dirs)
        before = RustCall.artifact_path_dependency_digest(joinpath(root, "main"))
        write(joinpath(root, "local_extra", "src", "lib.rs"), "pub fn e() -> i32 { 2 }\n")
        @test RustCall.artifact_path_dependency_digest(joinpath(root, "main")) != before

        # A workspace member's `[patch]` lives in the root manifest, and the
        # path there is relative to the root, not to the member.
        mkpath(joinpath(root, "ws", "member", "src")); mkpath(joinpath(root, "ws", "vendored", "src"))
        write(joinpath(root, "ws", "Cargo.toml"), """
            [workspace]
            members = ["member"]

            [patch.crates-io]
            extra = { path = "vendored" }
            """)
        write(joinpath(root, "ws", "vendored", "Cargo.toml"), """
            [package]
            name = "extra"
            version = "0.1.0"
            edition = "2021"
            """)
        write(joinpath(root, "ws", "vendored", "src", "lib.rs"), "pub fn v() -> i32 { 1 }\n")
        write(joinpath(root, "ws", "member", "Cargo.toml"), """
            [package]
            name = "member"
            version = "0.1.0"
            edition = "2021"

            [features]
            with_extra = ["dep:extra"]

            [dependencies]
            extra = { version = "0.1", optional = true }
            """)
        write(joinpath(root, "ws", "member", "src", "lib.rs"), "pub fn m() -> i32 { 1 }\n")
        @test joinpath(root, "ws", "vendored", "src", "lib.rs") in
              RustCall._crate_precompile_dependencies(joinpath(root, "ws", "member"))
        before = RustCall.artifact_path_dependency_digest(joinpath(root, "ws", "member"))
        write(joinpath(root, "ws", "vendored", "src", "lib.rs"), "pub fn v() -> i32 { 2 }\n")
        @test RustCall.artifact_path_dependency_digest(joinpath(root, "ws", "member")) != before
    end
end

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

# `PYO3_CONFIG_FILE` is an input by content, so the file is declared; its
# directory is not — an unrelated sibling appearing beside a configuration that
# lives outside the crate tree changes nothing the build reads, and tracking
# the directory would re-precompile the package for it (#339 review).
@testset "PYO3_CONFIG_FILE is tracked as a file, not with its directory (#339 review)" begin
    if !isdir(PRECOMP_SAMPLE_CRATE)
        @test_skip "test/fixtures/sample_crate is required"
    else
        mktempdir() do dir
            config = joinpath(dir, "pyo3-build-config.txt")
            write(config, "implementation=CPython\nversion=3.12\nshared=true\n")
            deps = withenv("PYO3_CONFIG_FILE" => config) do
                RustCall._crate_precompile_dependencies(PRECOMP_SAMPLE_CRATE)
            end
            @test normpath(config) in deps
            @test normpath(dir) ∉ deps
            @test normpath(config) ∉ withenv("PYO3_CONFIG_FILE" => nothing) do
                RustCall._crate_precompile_dependencies(PRECOMP_SAMPLE_CRATE)
            end
        end
    end
end

# Part of the artifact identity is not a file — `RUSTFLAGS`, `PYO3_PYTHON`, a
# `PYO3_CONFIG_FILE` pointing somewhere else — and Julia invalidates a
# precompile image from files alone. The module cannot make the image stale, so
# it records the values it was built under and says so at load time rather than
# loading a library built for another environment in silence (#339 review).
@testset "A changed build environment is reported at load time (#339 review)" begin
    # The recorded set is what `_recorded_build_env` captures at generation —
    # the allowlist plus RustCall's own selectors — so it is taken from the same
    # environment the comparison starts in.
    withenv("RUSTFLAGS" => "-C target-cpu=native", "PYO3_PYTHON" => "/usr/bin/python3") do
        recorded = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env()]
        @test any(p -> first(p) == "PYO3_PYTHON", recorded)

        # Unchanged: nothing to say.
        @test_logs RustCall._warn_if_build_env_changed(recorded, "/crate", "lib")

        # Pointing elsewhere: warned, which is the case Julia's file-based
        # invalidation cannot see.
        withenv("PYO3_PYTHON" => "/opt/py/bin/python3") do
            @test_logs (:warn,) match_mode = :any RustCall._warn_if_build_env_changed(
                recorded, "/crate", "lib")
            @test_throws RustCall.RustError RustCall._warn_if_build_env_changed(
                recorded, "/crate", "lib"; strict = true)
        end
        withenv("RUSTFLAGS" => "-C opt-level=1") do
            @test_throws RustCall.RustError RustCall._warn_if_build_env_changed(
                recorded, "/crate", "lib"; strict = true)
        end

        # Gone away: warned too.
        withenv("PYO3_PYTHON" => nothing) do
            @test_logs (:warn,) match_mode = :any RustCall._warn_if_build_env_changed(
                recorded, "/crate", "lib")
        end
    end

    # `CARGO_HOME` selects the effective Cargo configuration and is *not* an
    # allowlisted variable — the file's contents go into the artifact identity
    # instead of its path — so pointing it elsewhere changes the flags a build
    # runs under while every recorded variable, and every tracked file, stays
    # as it was. The recorded digest is what notices (#339 review).
    mktempdir() do home
        mkpath(joinpath(home, "a"))
        mkpath(joinpath(home, "b"))
        write(joinpath(home, "a", "config.toml"), "[build]\nrustflags = [\"-C\", \"opt-level=1\"]\n")
        write(joinpath(home, "b", "config.toml"), "[build]\nrustflags = [\"-C\", \"opt-level=3\"]\n")
        crate = joinpath(home, "crate"); mkpath(crate)
        digest_a = withenv("CARGO_HOME" => joinpath(home, "a")) do
            RustCall._cargo_config_digest(ENV; dir = crate)
        end
        digest_b = withenv("CARGO_HOME" => joinpath(home, "b")) do
            RustCall._cargo_config_digest(ENV; dir = crate)
        end
        @test digest_a != digest_b

        # No allowlisted variable moves between the two, so only the digest
        # can tell them apart.
        env_a = withenv("CARGO_HOME" => joinpath(home, "a")) do
            Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env()]
        end
        withenv("CARGO_HOME" => joinpath(home, "a")) do
            @test_logs RustCall._warn_if_build_env_changed(env_a, crate, "lib", digest_a)
        end
        withenv("CARGO_HOME" => joinpath(home, "b")) do
            @test_logs (:warn,) match_mode = :any RustCall._warn_if_build_env_changed(
                env_a, crate, "lib", digest_a)
        end
    end

    # The config selections are spliced into the wrapper module's tracked
    # inputs as `String[...; last.(selections)]`: a Vector of pairs, or that
    # splice is one unconvertible tuple (it was, once).
    let sel = RustCall._python_config_selections()
        @test sel isa Vector
        @test String[String[]; last.(sel)] isa Vector{String}
    end

    # `RUSTCALL_PYTHON_LIBDIR` is RustCall's own selector, outside the
    # allowlist, and it decides a PyO3 wrapper's rpath and identity: it is
    # recorded and compared like the rest (#339 review).
    withenv("RUSTCALL_PYTHON_LIBDIR" => "/opt/py-a/lib") do
        recorded = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env(; python = true)]
        @test any(p -> first(p) == "RUSTCALL_PYTHON_LIBDIR", recorded)
        @test_logs RustCall._warn_if_build_env_changed(recorded, "/crate", "lib"; python = true)
        withenv("RUSTCALL_PYTHON_LIBDIR" => "/opt/py-b/lib") do
            @test_logs (:warn,) match_mode = :any RustCall._warn_if_build_env_changed(
                recorded, "/crate", "lib"; python = true)
        end
        # The implicit selection moves with `PATH` when nothing pins it: the
        # old interpreter is still there and unchanged, so only the recorded
        # selection can say so (#339 review).
        # The fake interpreters and `python3-config`s below are shell scripts:
        # on Windows `Sys.which` looks for `.exe`/PATHEXT and a script does
        # not run, so this block — the precedence contract included, which
        # puts a fake `python3` on `PATH` — is Unix-only. The recorded-set
        # tests above run everywhere.
        Sys.iswindows() || mktempdir() do fake
            # A shim that reports itself as `sys.executable` would: the
            # selection is what the interpreter *says* it is, not the command
            # found on `PATH`, so a pyenv/asdf shim whose target moved is seen.
            exe = joinpath(fake, "python3")
            write(exe, "#!/bin/sh\necho \"$fake/python3\"\n"); chmod(exe, 0o755)
            withenv("PYO3_PYTHON" => nothing) do
                before = RustCall._python_selection()
                withenv("PATH" => fake * (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")) do
                    @test RustCall._python_selection() == exe
                    @test RustCall._python_selection() != before
                end
            end
            withenv("PYO3_PYTHON" => "/pinned/python3") do
                @test RustCall._python_selection() == "/pinned/python3"
                recorded = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env(; python = true)]
                @test any(p -> first(p) == "<python selection>", recorded)
            end
            # `python3-config` decides the implicit link directory, and `PATH`
            # may resolve it to another installation than the interpreter's:
            # its selection is recorded and compared too (#339 review).
            cfgexe = joinpath(fake, "python3-config")
            write(cfgexe, "#!/bin/sh\necho -L$fake\n"); chmod(cfgexe, 0o755)
            # The machine's own `python3` may be a framework build (macOS),
            # for which the commands are never consulted — see below — so the
            # implicit interpreter here is a fake that is not one: a directory
            # holding only it, ahead of `PATH`, and answering with the same
            # `sys.executable` as `exe` so that only the config command moves
            # between the record and the comparison.
            plain = mkpath(joinpath(fake, "plain"))
            write(joinpath(plain, "python3"), "#!/bin/sh\necho \"$fake/python3\"\n")
            chmod(joinpath(plain, "python3"), 0o755)
            withenv("PYO3_PYTHON" => nothing, "RUSTCALL_PYTHON_LIBDIR" => nothing,
                    "PATH" => plain * (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")) do
                recorded = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env(; python = true)]
                @test any(p -> first(p) == "<python3-config selection>", recorded)
                @test any(p -> first(p) == "<python-config selection>", recorded)
                @test any(p -> first(p) == "<python fingerprint>", recorded)
                # With `PYO3_PYTHON` deciding, neither config command is
                # consulted, so neither is recorded (#339 review).
                withenv("PYO3_PYTHON" => exe) do
                    pinned = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env(; python = true)]
                    @test !any(p -> occursin("-config selection", first(p)), pinned)
                    @test !RustCall._python_link_is_implicit()
                end
                @test RustCall._python_link_is_implicit()
                # The fake interpreter names a *file* as its framework prefix,
                # so it is no framework build and the commands are consulted.
                @test RustCall._python_config_consulted()
                @test_logs RustCall._warn_if_build_env_changed(recorded, "/crate", "lib"; python = true)
                withenv("PATH" => fake * (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")) do
                    @test Dict(RustCall._python_config_selections())["python3-config"] == cfgexe
                    @test_logs (:warn,) match_mode = :any RustCall._warn_if_build_env_changed(
                        recorded, "/crate", "lib"; python = true)
                end
            end
            # The *answer* is recorded, not only the command: an unchanged
            # `python3-config` that is a shim can name another directory once
            # what it reads moves, and the wrapper's `-L`/rpath follow that
            # answer (`pyo3_link_rustflags`). Same executable, same `PATH`,
            # different `-L` → a warning; same answer → none (#339 review).
            lib_a = mkpath(joinpath(fake, "lib-a"))
            lib_b = mkpath(joinpath(fake, "lib-b"))
            write(cfgexe, "#!/bin/sh\necho -L\$RUSTCALL_TEST_PY_LIBDIR\n"); chmod(cfgexe, 0o755)
            withenv("PYO3_PYTHON" => nothing, "RUSTCALL_PYTHON_LIBDIR" => nothing,
                    "PATH" => fake * (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")) do
                recorded = withenv("RUSTCALL_TEST_PY_LIBDIR" => lib_a) do
                    Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env(; python = true)]
                end
                @test Dict(recorded)["<python link dir>"] == lib_a
                @test Dict(recorded)["<python link dir>"] == withenv("RUSTCALL_TEST_PY_LIBDIR" => lib_a) do
                    RustCall.python_link_source()[1]
                end
                withenv("RUSTCALL_TEST_PY_LIBDIR" => lib_a) do
                    @test_logs RustCall._warn_if_build_env_changed(recorded, "/crate", "lib"; python = true)
                end
                withenv("RUSTCALL_TEST_PY_LIBDIR" => lib_b) do
                    @test_logs (:warn,) match_mode = :any RustCall._warn_if_build_env_changed(
                        recorded, "/crate", "lib"; python = true)
                end
            end
            # A framework build of Python (macOS) answers with its framework
            # prefix, and `python_link_source()` never runs `python3-config`
            # for it: the commands are not inputs, so neither is recorded nor
            # tracked, and a changed `python3-config` on `PATH` cannot warn
            # (#339 review). The fake prints an existing *directory* for every
            # probe, which is what the framework-prefix question sees.
            framework = joinpath(fake, "framework")
            mkpath(joinpath(framework, "bin"))
            write(joinpath(framework, "bin", "python3"), "#!/bin/sh\necho \"$framework\"\n")
            chmod(joinpath(framework, "bin", "python3"), 0o755)
            withenv("PYO3_PYTHON" => nothing, "RUSTCALL_PYTHON_LIBDIR" => nothing,
                    "PATH" => joinpath(framework, "bin") * (Sys.iswindows() ? ";" : ":") * fake *
                              (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")) do
                @test RustCall._python_link_is_implicit()
                @test RustCall._python_config_consulted() == !Sys.isapple()
                recorded = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env(; python = true)]
                @test any(p -> occursin("-config selection", first(p)), recorded) == !Sys.isapple()
                if Sys.isapple()
                    @test Dict(recorded)["<python link dir>"] == framework
                end
            end
            # `RUSTCALL_PYTHON_LIBDIR` is the directory whatever else says, and
            # the record follows the same precedence (#339 review).
            withenv("RUSTCALL_PYTHON_LIBDIR" => lib_b, "PYO3_PYTHON" => nothing) do
                recorded = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env(; python = true)]
                @test Dict(recorded)["<python link dir>"] == lib_b
            end
            write(cfgexe, "#!/bin/sh\necho -L$fake\n"); chmod(cfgexe, 0o755)
            # The `python-config` fallback is a selector of its own: it is what
            # answers when `python3-config` is absent or names no library
            # directory, and `PATH` may move it alone (#339 review).
            withenv("PYO3_PYTHON" => nothing, "RUSTCALL_PYTHON_LIBDIR" => nothing) do
                recorded = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env(; python = true)]
                fallback = joinpath(fake, "python-config")
                write(fallback, "#!/bin/sh\necho -L$fake\n"); chmod(fallback, 0o755)
                withenv("PATH" => fake * (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")) do
                    @test Dict(RustCall._python_config_selections())["python-config"] == fallback
                    @test_logs (:warn,) match_mode = :any RustCall._warn_if_build_env_changed(
                        recorded, "/crate", "lib"; python = true)
                end
                rm(fallback)
            end
            # `PYO3_PYTHON` given as a bare command or a shim: the raw value is
            # the selection (it is what `python_link_source()` pins), and what
            # it *resolves to* is recorded beside it, so the same name pointing
            # at another interpreter is seen (#339 review).
            withenv("PYO3_PYTHON" => "python3",
                    "PATH" => fake * (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")) do
                @test RustCall._python_selection() == "python3"
                @test RustCall._python_resolved("python3") == exe
                recorded = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env(; python = true)]
                @test ("<python resolved>" => exe) in recorded
                @test_logs RustCall._warn_if_build_env_changed(recorded, "/crate", "lib"; python = true)
                other = joinpath(fake, "other"); mkpath(other)
                write(joinpath(other, "python3"), "#!/bin/sh\necho \"$other/python3\"\n")
                chmod(joinpath(other, "python3"), 0o755)
                withenv("PATH" => other * (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")) do
                    @test RustCall._python_selection() == "python3"        # unchanged
                    @test_logs (:warn,) match_mode = :any RustCall._warn_if_build_env_changed(
                        recorded, "/crate", "lib"; python = true)         # but resolved moved
                end
            end

            # The selector follows `python_link_source()` step for step, and
            # the contract is that the two agree — here, and under the two
            # precedences that differ from "pinned, else PATH": pyo3's own
            # configuration leaves the interpreter to `PYO3_PYTHON` alone, and
            # `RUSTCALL_PYTHON_LIBDIR` hands it to `PATH` before CondaPkg
            # (#339 review).
            agree() = RustCall._python_selection() == RustCall.python_link_source()[2]
            withenv("PYO3_PYTHON" => nothing, "RUSTCALL_PYTHON_LIBDIR" => nothing,
                    "PYO3_CONFIG_FILE" => nothing, "PYO3_CROSS_LIB_DIR" => nothing) do
                @test agree()
            end
            config = joinpath(fake, "pyo3-config.txt")
            write(config, "implementation=CPython\nversion=3.12\nlib_dir=$fake\n")
            withenv("PYO3_CONFIG_FILE" => config, "PYO3_PYTHON" => nothing) do
                @test RustCall._python_selection() == ""
                @test agree()
            end
            withenv("PYO3_CONFIG_FILE" => config, "PYO3_PYTHON" => "/pinned/python3") do
                @test RustCall._python_selection() == "/pinned/python3"
                @test agree()
            end
            withenv("RUSTCALL_PYTHON_LIBDIR" => fake, "PYO3_PYTHON" => nothing,
                    "PYO3_CONFIG_FILE" => nothing,
                    "PATH" => fake * (Sys.iswindows() ? ";" : ":") * get(ENV, "PATH", "")) do
                @test RustCall._python_selection() == exe
                @test agree()
            end
        end

        # A plain crate's build never consults it: not recorded, not compared,
        # so configuring Python for another package warns about nothing here.
        plain = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env()]
        @test !any(p -> first(p) == "RUSTCALL_PYTHON_LIBDIR", plain)
        withenv("RUSTCALL_PYTHON_LIBDIR" => "/opt/py-b/lib") do
            @test_logs RustCall._warn_if_build_env_changed(plain, "/crate", "lib")
        end
    end

    # And the toolchain: the fingerprint is in the artifact identity, and a
    # `rustup update` moves no file the image tracks (#339 review).
    let recorded = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env()],
        now = RustCall.toolchain_fingerprint()
        @test_logs RustCall._warn_if_build_env_changed(recorded, "/crate", "lib", "", now)
        @test_logs (:warn,) match_mode = :any RustCall._warn_if_build_env_changed(
            recorded, "/crate", "lib", "", "not-" * now)
    end
end

# The plain-crate cache key covers the captured build environment, as the PyO3
# wrapper's already did. Without it a changed `RUSTFLAGS` found the previous
# library in the cache and handed it back — and the load-time warning's advice
# was then wrong, because re-precompiling the package rebuilt the bindings
# around the same stale artifact (#339 review).
# When pyo3's own configuration decides the link directory, pyo3 consults no
# interpreter: the plan's fingerprint is "" and the wrapper's identity keys
# nothing by what `PYO3_PYTHON` resolves to. The record is empty there too —
# a `PYTHONHOME` change or a retargeted shim must not warn about a library the
# same environment would select again (#339 review).
@testset "Interpreter records follow the link plan (#339 review)" begin
    mktempdir() do dir
        config = joinpath(dir, "pyo3-build-config.txt")
        write(config, "implementation=CPython\nversion=3.12\nshared=true\nlib_dir=$dir\n")
        withenv("PYO3_CONFIG_FILE" => config, "PYO3_CROSS_LIB_DIR" => nothing,
                "PYO3_PYTHON" => "/pinned/python3", "RUSTCALL_PYTHON_LIBDIR" => nothing) do
            recorded = Dict(String(k) => String(v) for (k, v) in RustCall._recorded_build_env(; python = true))
            @test recorded["<python selection>"] == "/pinned/python3"
            @test recorded["<python resolved>"] == ""
            @test recorded["<python fingerprint>"] == ""
            @test recorded["<python fingerprint>"] == RustCall.python_link_source()[3]
            @test recorded["<python link dir>"] == dir
        end
        # Off that branch the fingerprint is the plan's, whatever it is here.
        withenv("PYO3_CONFIG_FILE" => nothing, "PYO3_CROSS_LIB_DIR" => nothing) do
            recorded = Dict(String(k) => String(v) for (k, v) in RustCall._recorded_build_env(; python = true))
            @test recorded["<python fingerprint>"] == RustCall.python_link_source()[3]
        end
    end
end

@testset "The plain crate key covers the build environment (#339 review)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        info = RustCall.scan_crate(PRECOMP_SAMPLE_CRATE)
        keys_of(flags) = withenv("RUSTFLAGS" => flags) do
            RustCall.compute_crate_hash(info; release = true,
                                        build_env = RustCall._plain_crate_build_env())
        end
        a = keys_of("-C target-cpu=native")
        b = keys_of("-C opt-level=1")
        @test a != b
        @test a == keys_of("-C target-cpu=native")
    end
end

# `PYO3_CONFIG_FILE` is on the allowlist by prefix, but what it *names* is a
# path, and a crate that depends on pyo3 reads the file's contents at build time.
# The wrapper path hashed those contents; the plain path keyed the path alone,
# so editing the configuration in place — another Python version, ABI or
# library directory — found the previous library in the cache (#339 review).
@testset "The plain crate key covers the contents of PYO3_CONFIG_FILE (#339 review)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        info = RustCall.scan_crate(PRECOMP_SAMPLE_CRATE)
        mktempdir() do dir
            config = joinpath(dir, "pyo3-build-config.txt")
            key_with(contents) = begin
                write(config, contents)
                withenv("PYO3_CONFIG_FILE" => config) do
                    RustCall.compute_crate_hash(info; release = true,
                                                build_env = RustCall._plain_crate_build_env())
                end
            end
            a = key_with("implementation=CPython\nversion=3.12\nshared=true\n")
            b = key_with("implementation=CPython\nversion=3.13\nshared=true\n")
            @test a != b                        # same path, edited contents
            @test a == key_with("implementation=CPython\nversion=3.12\nshared=true\n")
            unset = withenv("PYO3_CONFIG_FILE" => nothing) do
                RustCall.compute_crate_hash(info; release = true,
                                            build_env = RustCall._plain_crate_build_env())
            end
            @test unset != a
            # Unset, the helper is the allowlist plus the interpreter pyo3's
            # build script would use: no digest entry.
            withenv("PYO3_CONFIG_FILE" => nothing) do
                env = RustCall._plain_crate_build_env()
                @test !any(p -> first(p) == "pyo3-config-file-digest", env)
                @test filter(p -> !startswith(first(p), "rustcall-pyo3-"), env) == RustCall.artifact_build_env()
            end
            withenv("PYO3_CONFIG_FILE" => config) do
                @test any(p -> first(p) == "pyo3-config-file-digest", RustCall._plain_crate_build_env())
            end
        end
    end
end

# Neither the `PYO3_*` values nor the contents of `PYO3_CONFIG_FILE` are gated
# on pyo3 being in the graph: Cargo hands every ambient variable to every build
# script, and a crate's own `build.rs` may read the variable, or open the file
# it names, without depending on pyo3. The sample crate has no pyo3 anywhere in
# its graph, and both stay inputs of its build (#339 review).
@testset "PYO3_* and the config file are inputs of every plain build (#339 review)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        info = RustCall.scan_crate(PRECOMP_SAMPLE_CRATE)
        key_under(python) = withenv("PYO3_PYTHON" => python) do
            RustCall.compute_crate_hash(info; release = true,
                                        build_env = RustCall._plain_crate_build_env())
        end
        @test key_under("/one/python3") != key_under("/two/python3")
        withenv("PYO3_PYTHON" => "/one/python3") do
            @test any(p -> first(p) == "PYO3_PYTHON", RustCall._plain_crate_build_env())
            @test any(p -> first(p) == "PYO3_PYTHON", RustCall._recorded_build_env())
        end
        mktempdir() do dir
            config = joinpath(dir, "pyo3-build-config.txt")
            write(config, "implementation=CPython\nversion=3.12\nshared=true\n")
            withenv("PYO3_CONFIG_FILE" => config) do
                @test any(p -> first(p) == "pyo3-config-file-digest", RustCall._plain_crate_build_env())
                @test normpath(config) in RustCall._crate_precompile_dependencies(PRECOMP_SAMPLE_CRATE)
            end
        end
    end
end

# A plain build of a crate that depends on pyo3 runs pyo3's build script, which
# configures the library for the interpreter it selects — `PYO3_PYTHON`, else
# `python3` on `PATH`. The raw `PYO3_*` values see neither a `PATH` that now
# finds another Python nor a shim retargeted under one name; the interpreter's
# identity does, and it is in the key and in the load-time record (#339
# review). Shell-script fakes: Unix only, as above.
@testset "A plain build is keyed by the interpreter pyo3 would configure for (#339 review)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        Sys.iswindows() || mktempdir() do fake
            sep = ":"
            for which in ("a", "b")
                dir = mkpath(joinpath(fake, which))
                exe = joinpath(dir, "python3")
                write(exe, "#!/bin/sh\necho \"$dir/python3\"\n"); chmod(exe, 0o755)
            end
            info = RustCall.scan_crate(PRECOMP_SAMPLE_CRATE)
            under(which) = withenv("PYO3_PYTHON" => nothing, "PYO3_CONFIG_FILE" => nothing,
                                   "PYO3_CROSS_LIB_DIR" => nothing,
                                   "PATH" => joinpath(fake, which) * sep * get(ENV, "PATH", "")) do
                (RustCall.compute_crate_hash(info; release = true,
                                             build_env = RustCall._plain_crate_build_env()),
                 Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env()],
                 RustCall._pyo3_build_interpreter())
            end
            key_a, recorded_a, (interp_a, _) = under("a")
            key_b, _, (interp_b, _) = under("b")
            @test interp_a == joinpath(fake, "a", "python3")
            @test interp_b == joinpath(fake, "b", "python3")
            @test key_a != key_b                       # same PYO3_*, another Python on PATH
            @test under("a")[1] == key_a
            @test Dict(recorded_a)["<pyo3 build interpreter>"] == interp_a
            withenv("PYO3_PYTHON" => nothing, "PYO3_CONFIG_FILE" => nothing, "PYO3_CROSS_LIB_DIR" => nothing,
                    "PATH" => joinpath(fake, "a") * sep * get(ENV, "PATH", "")) do
                @test_logs RustCall._warn_if_build_env_changed(recorded_a, info.path, "lib")
            end
            withenv("PYO3_PYTHON" => nothing, "PYO3_CONFIG_FILE" => nothing, "PYO3_CROSS_LIB_DIR" => nothing,
                    "PATH" => joinpath(fake, "b") * sep * get(ENV, "PATH", "")) do
                @test_logs (:warn,) match_mode = :any RustCall._warn_if_build_env_changed(recorded_a, info.path, "lib")
            end
            # `PYO3_PYTHON` is taken as given, the way pyo3's build script does.
            withenv("PYO3_PYTHON" => joinpath(fake, "b", "python3"), "PYO3_CONFIG_FILE" => nothing,
                    "PYO3_CROSS_LIB_DIR" => nothing) do
                @test RustCall._pyo3_build_interpreter()[1] == joinpath(fake, "b", "python3")
            end
            # pyo3's own configuration deciding: no interpreter is consulted,
            # and none is keyed or recorded.
            config = joinpath(fake, "pyo3-build-config.txt")
            write(config, "implementation=CPython\nversion=3.12\nshared=true\nlib_dir=$fake\n")
            withenv("PYO3_CONFIG_FILE" => config, "PYO3_PYTHON" => joinpath(fake, "a", "python3"),
                    "PYO3_CROSS_LIB_DIR" => nothing) do
                @test RustCall._pyo3_build_interpreter() == ("", "")
                @test !any(p -> startswith(first(p), "rustcall-pyo3-python"), RustCall._plain_crate_build_env())
                @test Dict(RustCall._recorded_build_env())["<pyo3 build interpreter>"] == ""
            end
        end
    end
end

# `PYO3_CONFIG_FILE` may name a file that does not exist yet; a build script that
# tolerates the absence is built without it, and the file appearing is then
# the one event that changes the build. Until it exists its directory is the
# declared input (the entry list sees the creation), afterwards the file is;
# and the record carries the contents' digest either way, so a load after the
# creation is told even when the image survived (#339 review).
@testset "A PYO3_CONFIG_FILE selected before it exists is seen appearing (#339 review)" begin
    mktempdir() do dir
        config = joinpath(dir, "pyo3-build-config.txt")
        withenv("PYO3_CONFIG_FILE" => config) do
            absent = RustCall._crate_precompile_dependencies(PRECOMP_SAMPLE_CRATE)
            @test normpath(dir) in absent
            @test normpath(config) ∉ absent
            recorded = Any[String(k) => String(v) for (k, v) in RustCall._recorded_build_env()]
            @test Dict(recorded)["<PYO3_CONFIG_FILE digest>"] == "unreadable"
            @test_logs RustCall._warn_if_build_env_changed(recorded, PRECOMP_SAMPLE_CRATE, "lib")
            write(config, "implementation=CPython\nversion=3.12\nshared=true\n")
            present = RustCall._crate_precompile_dependencies(PRECOMP_SAMPLE_CRATE)
            @test normpath(config) in present
            @test normpath(dir) ∉ present
            @test_logs (:warn,) match_mode = :any RustCall._warn_if_build_env_changed(recorded, PRECOMP_SAMPLE_CRATE, "lib")
        end
        withenv("PYO3_CONFIG_FILE" => nothing) do
            @test Dict(RustCall._recorded_build_env())["<PYO3_CONFIG_FILE digest>"] == ""
        end
    end
end

# The registry name and the cache key must be decided by the *same* environment
# snapshot. Keying only the cache gave two builds under different environments
# distinct artifacts under one `_LIB_NAME`, and loading the second replaced the
# first module's entry and mirror (#339 review).
@testset "The registry name follows the build environment too (#339 review)" begin
    if !RustCall.check_rustc_available()
        @test_skip "rustc is required"
    else
        info = RustCall.scan_crate(PRECOMP_SAMPLE_CRATE)
        pair(flags) = withenv("RUSTFLAGS" => flags) do
            env = RustCall._plain_crate_build_env()
            (RustCall.compute_crate_hash(info; release = true, build_env = env),
             RustCall.crate_library_name(info; release = true, build_env = env))
        end
        a_key, a_name = pair("-C target-cpu=native")
        b_key, b_name = pair("-C opt-level=1")
        @test a_key != b_key
        @test a_name != b_name        # the name moves with the key, not apart from it
        @test pair("-C target-cpu=native") == (a_key, a_name)
    end
end
