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
            @test !occursin("rust_helpers\", \"target", src)
        end
    end

    @testset "the UUID Scratch namespaces by is the package's own" begin
        project = TOML.parsefile(joinpath(_REPO_ROOT, "Project.toml"))
        @test RustCall.RUSTCALL_UUID == Base.UUID(project["uuid"])
    end

    @testset "each product names a crate that exists" begin
        for kind in (:rust_helpers, :extractor)
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
        for kind in (:rust_helpers, :extractor)
            @test RustCall.native_target_dir(kind) ==
                  joinpath(RustCall.native_crate_dir(kind), "target")
        end
        # ...and, overrides aside, nothing outside that tree is offered as a
        # candidate, so a checkout's lookup cannot pick up another copy's build.
        withenv("RUSTCALL_EXTRACT" => nothing, "RUSTCALL_RUST_HELPERS" => nothing) do
            for kind in (:rust_helpers, :extractor)
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
        withenv("RUSTCALL_RUST_HELPERS" => probe) do
            @test first(RustCall.native_product_candidates(:rust_helpers)) == probe
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
        for kind in (:rust_helpers, :extractor)
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
        println(m.native_target_dir(:rust_helpers))
        for c in m.native_product_candidates(:extractor)
            println("candidate: ", c)
        end
        """
        # The probe must see the layout, not this session's overrides.
        out = withenv("RUSTCALL_EXTRACT" => nothing,
                      "RUSTCALL_RUST_HELPERS" => nothing) do
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
        @test helpers_dir == joinpath(expected, "rust_helpers")
        # `create = true` really created it, and the package tree stayed clean.
        @test isdir(extractor_dir)
        @test !ispath(joinpath(pkg, "deps", "rustcall_extract", "target"))
        @test !ispath(joinpath(pkg, "deps", "rust_helpers", "target"))
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
        for kind in (:rust_helpers, :extractor)
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
                        for kind in (:rust_helpers, :extractor)]
            @test all(p -> p !== nothing, products)
            # A no-op Cargo build writes nothing: not the products, and not
            # the lockfiles, which `--locked` keeps Cargo from touching even
            # though they sit inside the package tree.
            watched = vcat(products,
                           [joinpath(RustCall.native_crate_dir(kind), "Cargo.lock")
                            for kind in (:rust_helpers, :extractor)])
            before = [(p, mtime(p), filesize(p)) for p in watched]
            run(pipeline(cmd; stdout = devnull, stderr = devnull))
            for (path, stamp, size) in before
                @test mtime(path) == stamp
                @test filesize(path) == size
            end
        end
    end
end
