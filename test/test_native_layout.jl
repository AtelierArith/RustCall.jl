using Test
using RustCall
using TOML

# Where `Pkg.build("RustCall")` puts the ownership helper library and the
# `rustcall-extract` CLI, and where a running RustCall looks for them again
# (#258).
#
# Two properties are at stake and both are asserted here:
#
#   1. A second build with unchanged sources rebuilds nothing. Through v0.3.4
#      `deps/build.jl` ran `cargo clean` first, so every build event paid a
#      full Rust compile; Cargo's own fingerprint is what replaces it.
#   2. An installed package's directory is never written to. A checkout keeps
#      building in `deps/<crate>/target`, where the documented developer
#      commands already put its products.

const _REPO_ROOT = dirname(@__DIR__)

_toolchain_required() =
    get(ENV, "CI", "false") == "true" ||
    get(ENV, "RUSTCALL_REQUIRE_TOOLCHAIN", "false") == "true"

@testset "native layout" begin
    @testset "the layout file is the only place that names these paths" begin
        # `deps/build.jl` runs before the module exists, so it includes the
        # very same file rather than keeping its own copy of the rules.
        build_jl = read(joinpath(_REPO_ROOT, "deps", "build.jl"), String)
        @test occursin("include(joinpath(@__DIR__, \"..\", \"src\", \"native_layout.jl\"))",
                       build_jl)
        @test occursin("native_target_dir", build_jl)
        @test occursin("native_product_filename", build_jl)
        # Neither side may compute a library name or a target path of its own.
        @test !occursin("target\", \"release", build_jl)
        @test !occursin("librust_helpers", build_jl)

        for file in ("memory.jl", "manifest.jl")
            src = read(joinpath(_REPO_ROOT, "src", file), String)
            @test !occursin("rustcall_extract\", \"target", src)
            @test !occursin("rustcall_helpers\", \"target", src)
            @test !occursin("rust_helpers\", \"target", src)
        end
    end

    @testset "the UUID Scratch namespaces by is the package's own" begin
        project = TOML.parsefile(joinpath(_REPO_ROOT, "Project.toml"))
        @test RustCall.RUSTCALL_UUID == Base.UUID(project["uuid"])
    end

    @testset "each product names a crate that exists" begin
        for kind in (:rustcall_helpers, :extractor)
            @test isfile(joinpath(RustCall.native_crate_dir(kind), "Cargo.toml"))
            @test !isempty(RustCall.native_product_filename(kind))
        end
        @test_throws ArgumentError RustCall.native_product_filename(:nope)
        @test_throws ArgumentError RustCall.native_crate_dir(:nope)
    end

    @testset "a checkout builds in its own tree" begin
        # The repository under test is a checkout, not an installed package.
        @test RustCall.native_installed_slug() === nothing
        @test RustCall.native_is_installed_package() === false
        for kind in (:rustcall_helpers, :extractor)
            @test RustCall.native_target_dir(kind) ==
                  joinpath(RustCall.native_crate_dir(kind), "target")
        end
        # ...and, overrides aside, nothing outside that tree is offered as a
        # candidate, so a checkout's lookup cannot pick up another copy's build.
        withenv("RUSTCALL_EXTRACT" => nothing, "RUSTCALL_HELPERS" => nothing, "RUSTCALL_RUST_HELPERS" => nothing) do
            for kind in (:rustcall_helpers, :extractor)
                for candidate in RustCall.native_product_candidates(kind)
                    @test startswith(candidate, RustCall.native_package_root())
                end
            end
        end
    end

    @testset "an environment override wins" begin
        probe = joinpath(mktempdir(), "rustcall-extract")
        withenv("RUSTCALL_EXTRACT" => probe) do
            @test first(RustCall.native_product_candidates(:extractor)) == probe
        end
        withenv("RUSTCALL_HELPERS" => probe, "RUSTCALL_RUST_HELPERS" => nothing) do
            @test first(RustCall.native_product_candidates(:rustcall_helpers)) == probe
        end
        # The pre-v0.4 variable is a deprecated alias: honoured when the new one
        # is unset, and it says so once (#387).
        legacy_probe = joinpath(mktempdir(), "librust_helpers.so")
        withenv("RUSTCALL_HELPERS" => nothing, "RUSTCALL_RUST_HELPERS" => legacy_probe) do
            candidates = @test_logs (:warn, r"RUSTCALL_RUST_HELPERS is deprecated") match_mode=:any begin
                RustCall.native_product_candidates(:rustcall_helpers)
            end
            @test first(candidates) == legacy_probe
        end
        # ...and it never shadows the new one.
        withenv("RUSTCALL_HELPERS" => probe, "RUSTCALL_RUST_HELPERS" => legacy_probe) do
            @test first(RustCall.native_product_candidates(:rustcall_helpers)) == probe
        end
        # An empty value is not an override: the checkout's own build wins.
        withenv("RUSTCALL_EXTRACT" => "") do
            @test first(RustCall.native_product_candidates(:extractor)) ==
                  joinpath(RustCall.native_crate_dir(:extractor), "target", "release",
                           RustCall.native_product_filename(:extractor))
        end
    end

    @testset "an installed package builds outside its own directory" begin
        # Pkg installs a package at `<depot>/packages/<Name>/<slug>`. Rather
        # than mock the predicate, this builds that shape for real and lets an
        # unrelated Julia process include the layout file from inside it.
        depot = mktempdir()
        pkg = joinpath(depot, "packages", "RustCall", "AbCdE")
        mkpath(joinpath(pkg, "src"))
        for kind in (:rustcall_helpers, :extractor)
            crate = joinpath(pkg, "deps", RustCall.NATIVE_PRODUCTS[kind].crate)
            mkpath(crate)
            write(joinpath(crate, "Cargo.toml"), "")
        end
        cp(joinpath(_REPO_ROOT, "src", "native_layout.jl"),
           joinpath(pkg, "src", "native_layout.jl"))

        # The probe process sees only the temporary depot, so the layout it
        # reports is the one an installed package would get. `Scratch` is
        # imported before that, while it is still reachable.
        script = """
        import Scratch
        empty!(DEPOT_PATH)
        push!(DEPOT_PATH, $(repr(depot)))
        m = Module(:NativeLayoutProbe)
        Base.include(m, $(repr(joinpath(pkg, "src", "native_layout.jl"))))
        println(m.native_installed_slug())
        println(m.native_target_dir(:extractor; create = true))
        println(m.native_target_dir(:rustcall_helpers))
        for c in m.native_product_candidates(:extractor)
            println("candidate: ", c)
        end
        """
        # The probe must see the layout, not this session's overrides.
        out = withenv("RUSTCALL_EXTRACT" => nothing,
                      "RUSTCALL_HELPERS" => nothing, "RUSTCALL_RUST_HELPERS" => nothing) do
            read(`$(Base.julia_cmd()) --project=$(_REPO_ROOT) --startup-file=no -e $script`,
                 String)
        end
        lines = split(strip(out), '\n')
        slug, extractor_dir, helpers_dir = lines[1], lines[2], lines[3]
        candidates = [replace(l, "candidate: " => "") for l in lines[4:end]]

        @test slug == "AbCdE"
        # The build products land in the depot's scratch space, keyed by the
        # slug so two installed versions never share a target directory.
        expected = joinpath(depot, "scratchspaces", string(RustCall.RUSTCALL_UUID),
                            RustCall.NATIVE_SCRATCH_NAME, "AbCdE")
        @test extractor_dir == joinpath(expected, "rustcall_extract")
        @test helpers_dir == joinpath(expected, "rustcall_helpers")
        # `create = true` really created it, and the package tree stayed clean.
        @test isdir(extractor_dir)
        @test !ispath(joinpath(pkg, "deps", "rustcall_extract", "target"))
        @test !ispath(joinpath(pkg, "deps", "rustcall_helpers", "target"))
        # The preferred candidate is that scratch build, never the tree.
        @test first(candidates) ==
              joinpath(extractor_dir, "release",
                       RustCall.native_product_filename(:extractor))

        # The scratch space of every depot is searched, and the pre-#258
        # in-package location remains a fallback for a tree built by an older
        # RustCall and not rebuilt since.
        @test any(c -> startswith(c, expected), candidates)
        @test any(c -> c == joinpath(pkg, "deps", "rustcall_extract", "target",
                                     "release", RustCall.native_product_filename(:extractor)),
                  candidates)
    end

    @testset "the pre-v0.4 helper name is still found, after the current one (#387)" begin
        # `deps/rust_helpers` / `librust_helpers` became `deps/rustcall_helpers` /
        # `librustcall_helpers` in v0.4.0. The file name is what a deployment
        # sees, so an installed tree built by v0.3.x — and not rebuilt since —
        # must keep loading for one release, from every place the current name
        # is looked for, and always *after* the current name.
        new_file = RustCall.native_product_filename(:rustcall_helpers)
        old_file = RustCall.native_legacy_helpers_filename()
        @test old_file == replace(new_file, "rustcall_helpers" => "rust_helpers")
        @test old_file != new_file

        withenv("RUSTCALL_HELPERS" => nothing, "RUSTCALL_RUST_HELPERS" => nothing) do
            candidates = RustCall.native_product_candidates(:rustcall_helpers)
            news = findall(c -> basename(c) == new_file, candidates)
            olds = findall(c -> basename(c) == old_file, candidates)
            @test !isempty(news)
            @test !isempty(olds)
            # Every current-name candidate precedes every legacy-name one.
            @test maximum(news) < minimum(olds)
            # A checkout: the legacy crate directory's own build is searched.
            @test joinpath(RustCall.native_package_root(), "deps", "rust_helpers",
                           "target", "release", old_file) in candidates
            # Nothing is ever *built* under the old name: no product is keyed by it.
            @test !haskey(RustCall.NATIVE_PRODUCTS, :rust_helpers)
            @test_throws ArgumentError RustCall.native_target_dir(:rust_helpers)
        end

        # An installed tree exactly as v0.3.x left it: only the old file exists,
        # in the old crate's scratch directory. It resolves.
        depot = mktempdir()
        pkg = joinpath(depot, "packages", "RustCall", "AbCdE")
        mkpath(joinpath(pkg, "src"))
        for crate in ("rustcall_helpers", "rustcall_extract", "rust_helpers")
            mkpath(joinpath(pkg, "deps", crate))
            write(joinpath(pkg, "deps", crate, "Cargo.toml"), "")
        end
        cp(joinpath(_REPO_ROOT, "src", "native_layout.jl"),
           joinpath(pkg, "src", "native_layout.jl"))
        old_build = joinpath(depot, "scratchspaces", string(RustCall.RUSTCALL_UUID),
                             RustCall.NATIVE_SCRATCH_NAME, "AbCdE", "rust_helpers", "release")
        mkpath(old_build)
        write(joinpath(old_build, old_file), "built by v0.3.x")
        script = """
        import Scratch
        empty!(DEPOT_PATH)
        push!(DEPOT_PATH, $(repr(depot)))
        m = Module(:NativeLayoutProbe)
        Base.include(m, $(repr(joinpath(pkg, "src", "native_layout.jl"))))
        println(something(m.native_product_path(:rustcall_helpers), "nothing"))
        println(first(m.native_product_candidates(:rustcall_helpers)))
        """
        out = withenv("RUSTCALL_HELPERS" => nothing, "RUSTCALL_RUST_HELPERS" => nothing) do
            read(`$(Base.julia_cmd()) --project=$(_REPO_ROOT) --startup-file=no -e $script`,
                 String)
        end
        resolved, preferred = split(strip(out), '\n')
        @test resolved == joinpath(old_build, old_file)
        # ...but a rebuild lands under the new name and would win.
        @test preferred == joinpath(depot, "scratchspaces", string(RustCall.RUSTCALL_UUID),
                                    RustCall.NATIVE_SCRATCH_NAME, "AbCdE",
                                    "rustcall_helpers", "release", new_file)
    end

    @testset "a read-only depot in front cannot shadow the build" begin
        # `Pkg.build` lands in the first *writable* depot. Enumerating
        # DEPOT_PATH in order for the lookup would prefer whatever the
        # read-only depot in front of it happens to carry for the same slug —
        # an older or wrong-architecture product — and silently ignore a
        # successful build. The lookup therefore asks the same function the
        # build asks, first.
        if Sys.iswindows()
            @test_skip "needs POSIX directory permissions"
        else
            root = mktempdir()
            frozen, live = joinpath(root, "frozen"), joinpath(root, "live")
            pkg = joinpath(live, "packages", "RustCall", "AbCdE")
            mkpath(joinpath(pkg, "src"))
            for kind in (:rustcall_helpers, :extractor)
                crate = joinpath(pkg, "deps", RustCall.NATIVE_PRODUCTS[kind].crate)
                mkpath(crate)
                write(joinpath(crate, "Cargo.toml"), "")
            end
            cp(joinpath(_REPO_ROOT, "src", "native_layout.jl"),
               joinpath(pkg, "src", "native_layout.jl"))

            # A stale product sitting in the depot that cannot be built into.
            stale_dir = joinpath(frozen, "scratchspaces",
                                 string(RustCall.RUSTCALL_UUID),
                                 RustCall.NATIVE_SCRATCH_NAME, "AbCdE",
                                 "rustcall_extract", "release")
            mkpath(stale_dir)
            stale = joinpath(stale_dir, RustCall.native_product_filename(:extractor))
            write(stale, "stale")
            chmod(joinpath(frozen, "scratchspaces"), 0o555)
            chmod(frozen, 0o555)

            # Running as root ignores the mode bits; then there is nothing to
            # assert, because the first depot really is writable.
            writable = try
                probe = joinpath(frozen, "scratchspaces", "probe")
                touch(probe)
                rm(probe; force = true)
                true
            catch
                false
            end

            if writable
                @test_skip "the frozen depot is writable (running as root?)"
            else
                script = """
                import Scratch
                empty!(DEPOT_PATH)
                append!(DEPOT_PATH, [$(repr(frozen)), $(repr(live))])
                m = Module(:NativeLayoutProbe)
                Base.include(m, $(repr(joinpath(pkg, "src", "native_layout.jl"))))
                println(m.native_target_dir(:extractor; create = true))
                for c in m.native_product_candidates(:extractor)
                    println("candidate: ", c)
                end
                """
                out = withenv("RUSTCALL_EXTRACT" => nothing,
                              "RUSTCALL_HELPERS" => nothing, "RUSTCALL_RUST_HELPERS" => nothing) do
                    read(`$(Base.julia_cmd()) --project=$(_REPO_ROOT) --startup-file=no -e $script`,
                         String)
                end
                lines = split(strip(out), '\n')
                built = lines[1]
                candidates = [replace(l, "candidate: " => "") for l in lines[2:end]]

                # The build goes to the writable depot behind the frozen one...
                @test startswith(built, joinpath(live, "scratchspaces"))
                # ...and that is the first place the lookup looks, ahead of the
                # stale copy, which is still reachable as a later candidate.
                @test first(candidates) ==
                      joinpath(built, "release",
                               RustCall.native_product_filename(:extractor))
                @test stale in candidates
                @test findfirst(==(stale), candidates) > 1
            end
            chmod(frozen, 0o755)
            chmod(joinpath(frozen, "scratchspaces"), 0o755)
        end
    end

    @testset "the build script never throws Cargo's knowledge away" begin
        # Through v0.3.4 every `Pkg.build("RustCall")` ran `cargo clean` first,
        # so each build event paid a full Rust compile. Cargo already knows
        # which of its inputs changed, down to the rustc version and the
        # profile; the build script's job is only to point it at one stable
        # target directory.
        build_jl = read(joinpath(_REPO_ROOT, "deps", "build.jl"), String)
        # An invocation, not the words: the comments explain what was dropped.
        @test !occursin(r"cargo\(\)\)?\s+clean", build_jl)
        @test !occursin("clean --manifest-path", build_jl)
        @test occursin("CARGO_TARGET_DIR", build_jl)
        # ...and the panic strategy is still pinned on the way in (#244).
        @test occursin("CARGO_PROFILE_RELEASE_PANIC", build_jl)
    end

    @testset "the build writes no lockfile into the package tree" begin
        # `CARGO_TARGET_DIR` does not move `Cargo.lock`: Cargo writes it beside
        # the manifest, inside the package directory, wherever the target
        # directory points. Both crates therefore commit their resolution and
        # are built with `--locked`, so Cargo asserts it rather than writes it.
        build_jl = read(joinpath(_REPO_ROOT, "deps", "build.jl"), String)
        @test occursin("--locked", build_jl)
        for kind in (:rustcall_helpers, :extractor)
            @test isfile(joinpath(RustCall.native_crate_dir(kind), "Cargo.lock"))
        end
    end

    @testset "a second build with unchanged sources rebuilds nothing" begin
        if !_toolchain_required()
            @test_skip "needs a Rust toolchain; set RUSTCALL_REQUIRE_TOOLCHAIN=true"
        else
            script = "include($(repr(joinpath(_REPO_ROOT, "deps", "build.jl"))))"
            cmd = `$(Base.julia_cmd()) --project=$(_REPO_ROOT) --startup-file=no -e $script`
            run(pipeline(cmd; stdout = devnull, stderr = devnull))

            products = [RustCall.native_product_path(kind)
                        for kind in (:rustcall_helpers, :extractor)]
            @test all(p -> p !== nothing, products)
            # A no-op Cargo build writes nothing: not the products, and not
            # the lockfiles, which `--locked` keeps Cargo from touching even
            # though they sit inside the package tree.
            watched = vcat(products,
                           [joinpath(RustCall.native_crate_dir(kind), "Cargo.lock")
                            for kind in (:rustcall_helpers, :extractor)])
            before = [(p, mtime(p), filesize(p)) for p in watched]
            run(pipeline(cmd; stdout = devnull, stderr = devnull))
            for (path, stamp, size) in before
                @test mtime(path) == stamp
                @test filesize(path) == size
            end
        end
    end
end
