# Component tests loaded by test_pyo3_link_plan.jl.

@testset "PyO3 link plan: wrapper and cfg probes" begin
    @testset "a cdylib-only crate is refused before the wrapper is built (#307 review)" begin
        # The wrapper depends on the crate as a Rust library; a `["cdylib"]`-only
        # `[lib]` has no rlib for it to link, and Cargo would build the wrapper
        # into "provides no linkable target" plus an unresolved crate.
        linkable = RustCall._linkable_lib_target
        @test linkable(_manifest("[package]\nname = \"a\"\n"))                 # Cargo's default: lib
        @test linkable(_manifest("[lib]\nname = \"a\"\n"))                     # no crate-type: lib
        @test linkable(_manifest("[lib]\ncrate-type = [\"rlib\"]\n"))
        @test linkable(_manifest("[lib]\ncrate-type = [\"cdylib\", \"rlib\"]\n"))
        @test linkable(_manifest("[lib]\ncrate-type = [\"lib\"]\n"))
        @test linkable(_manifest("[lib]\ncrate-type = [\"dylib\"]\n"))
        @test !linkable(_manifest("[lib]\ncrate-type = [\"cdylib\"]\n"))
        @test !linkable(_manifest("[lib]\ncrate-type = [\"staticlib\"]\n"))
        @test !linkable(_manifest("[lib]\ncrate-type = [\"cdylib\", \"staticlib\"]\n"))

        err = try
            RustCall._require_linkable_lib_target("ext", _manifest("[lib]\ncrate-type = [\"cdylib\"]\n"))
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        msg = sprint(showerror, err)
        @test occursin("`ext` declares `[lib] crate-type = [\"cdylib\"]`", msg)
        @test occursin("crate-type = [\"cdylib\", \"rlib\"]", msg)

        # End to end: a crate with something to wrap but nothing to link is
        # refused by `build_pyo3_wrapper` before any Cargo project exists — and
        # after the "nothing to wrap" decision, so a crate that exposes nothing
        # still falls back to the plain path rather than erroring here.
        if !RustCall.check_rustc_available()
            @test_skip "the extractor is required to scan a crate"
        else
            mktempdir() do dir
                _write_crate(dir, """
                    [package]
                    name = "cdylib_only"
                    version = "0.1.0"
                    edition = "2021"

                    [lib]
                    crate-type = ["cdylib"]
                    """)
                write(joinpath(dir, "src", "lib.rs"), """
                    #[pyfunction]
                    pub fn answer() -> i32 { 42 }
                    """)
                info = RustCall.scan_crate(dir)
                plan = RustCall.PyO3LinkPlan(:python_free, String[], "", "test"; resolved = true,
                                             cfg_text = "unix\n")
                err = try
                    RustCall.build_pyo3_wrapper(info; plan = plan, cache_enabled = false)
                    nothing
                catch e
                    e
                end
                @test err isa RustCall.RustError
                @test occursin("\"rlib\"", sprint(showerror, err))
                @test !isdir(joinpath(dir, "target"))
            end
        end
    end

    @testset "the cfg probe runs under the plan's interpreter (#307 review)" begin
        # The wrapper build pins `PYO3_PYTHON` to the plan's interpreter and
        # `pyo3-build-config` derives `Py_3_x` cfgs from it; a probe that
        # inherited the environment asked whatever Python pyo3 finds on its
        # own — the system one while the plan had chosen CondaPkg's.
        python = joinpath(@__DIR__, "conda-env", "bin", "python")
        pinned = withenv("PYO3_PYTHON" => nothing) do
            RustCall._wrapper_probe_env(@__DIR__, true, python)
        end
        @test pinned["PYO3_PYTHON"] == python
        @test pinned["CARGO_PROFILE_RELEASE_PANIC"] == "unwind"
        # The wrapper's own target directory under RustCall's cache, never
        # the crate's `target/` (#486).
        @test pinned["CARGO_TARGET_DIR"] ==
              RustCall.crate_target_directory(@__DIR__, :pyo3_wrapper)
        # No interpreter to pin (a `:python_free` build, or none found): the
        # environment is left as it is, so pyo3's own lookup still applies.
        unpinned = withenv("PYO3_PYTHON" => nothing) do
            RustCall._wrapper_probe_env(@__DIR__, false, "")
        end
        @test !haskey(unpinned, "PYO3_PYTHON")
        @test unpinned["CARGO_PROFILE_DEV_PANIC"] == "unwind"
    end

    @testset "the conservative plan keeps the requested features (#307 review)" begin
        # When Cargo cannot resolve the crate the plan is read off Cargo.toml,
        # but the wrapper's dependency entry is still written from the plan:
        # dropping the caller's `features` / `default_features` there would
        # build the crate's default configuration instead of the requested one.
        toml = _manifest("""
            [package]
            name = "opt"
            version = "0.1.0"
            [dependencies]
            pyo3 = { version = "0.22", optional = true }
            [features]
            python = ["pyo3"]
            """)
        flags = RustCall._pyo3_feature_flags(["python"], false)
        plan = RustCall._pyo3_conservative_plan(toml; flags = flags, features = ["python"],
                                                default_features = false)
        @test !plan.resolved
        @test plan.feature_flags == flags
        @test plan.crate_features == ["python"]
        @test !plan.dependency_default_features
        entry = RustCall.pyo3_dependency_toml(plan, "opt", "/crates/opt")
        @test occursin("default-features = false", entry)
        @test occursin("features = [\"python\"]", entry)
        # The same through `pyo3_link_plan` on a crate Cargo cannot resolve (no
        # such registry package), which is where the fallback is taken.
        mktempdir() do dir
            _write_crate(dir, """
                [package]
                name = "unresolvable"
                version = "0.1.0"
                edition = "2021"
                [dependencies]
                pyo3 = { version = "0.22", optional = true }
                rustcall-no-such-package-ever = "=99.99.99"
                [features]
                python = ["pyo3"]
                """)
            fallback = RustCall.pyo3_link_plan(dir; features = ["python"], default_features = false)
            if !fallback.resolved
                @test fallback.feature_flags == flags
                @test fallback.crate_features == ["python"]
                @test !fallback.dependency_default_features
            else
                @test_skip "Cargo resolved a crate it was expected to reject"
            end
        end
        # Without a request the plan is the default build, as before.
        default = RustCall._pyo3_conservative_plan(toml)
        @test default.feature_flags == String[] && default.crate_features == String[]
        @test default.dependency_default_features
    end

    @testset "a library root outside the package is part of the identity (#307 review)" begin
        # `[lib] path = "../shared/lib.rs"` is followed by the scan but lies
        # outside the directory `crate_content_digest` hashes; an edit there
        # left the key unchanged and the cache answered with the old wrapper.
        mktempdir() do top
            shared = joinpath(top, "shared")
            mkpath(shared)
            write(joinpath(shared, "lib.rs"), "pub mod part;\n#[pyfunction] pub fn f() -> i32 { 1 }\n")
            write(joinpath(shared, "part.rs"), "pub fn g() -> i32 { 2 }\n")
            write(joinpath(shared, "notes.txt"), "not source\n")
            crate = _write_crate(joinpath(top, "pkg"), """
                [package]
                name = "pkg"
                version = "0.1.0"
                edition = "2021"
                [lib]
                path = "../shared/lib.rs"
                """)
            rm(joinpath(crate, "src"); recursive = true, force = true)
            lib_root = RustCall.crate_lib_root(crate, RustCall.parse_cargo_toml(joinpath(crate, "Cargo.toml")))
            @test lib_root == normpath(joinpath(shared, "lib.rs"))
            digest = RustCall.external_lib_tree_digest(crate, lib_root)
            @test digest isa String
            # The root, its module tree, and every other file beside them count
            # — an `include_str!` of `notes.txt` compiles different bytes when
            # it changes, as it would inside the package directory.
            write(joinpath(shared, "part.rs"), "pub fn g() -> i32 { 3 }\n")
            changed = RustCall.external_lib_tree_digest(crate, lib_root)
            @test changed != digest
            write(joinpath(shared, "notes.txt"), "included data, revised\n")
            @test RustCall.external_lib_tree_digest(crate, lib_root) != changed
            # ... under the package walk's exclusions: build output is not input.
            mkpath(joinpath(shared, "target"))
            write(joinpath(shared, "target", "junk.rs"), "// output\n")
            with_target = RustCall.external_lib_tree_digest(crate, lib_root)
            rm(joinpath(shared, "target"); recursive = true, force = true)
            @test RustCall.external_lib_tree_digest(crate, lib_root) == with_target
            # An in-tree root is already covered by the package digest.
            @test RustCall.external_lib_tree_digest(crate, joinpath(crate, "src", "lib.rs")) === nothing
            @test RustCall.external_lib_tree_digest(crate, nothing) === nothing
            # ... and it reaches the artifact key of a crate bound this way.
            if !RustCall.check_rustc_available()
                @test_skip "the extractor is required to scan a crate"
            else
                info = RustCall.scan_crate(crate)
                before = RustCall.compute_crate_hash(info)
                write(joinpath(shared, "lib.rs"),
                      "pub mod part;\n#[pyfunction] pub fn f() -> i32 { 10 }\n")
                RustCall._artifact_reset_digest_caches!()
                @test RustCall.compute_crate_hash(info) != before
            end
        end
    end

    @testset "the dispatcher alias names the resolved pyo3, not a registry copy (#370)" begin
        # A version-only alias resolves a *second* pyo3 from crates.io whenever
        # the crate gets its own from a path or a git checkout. Two instances in
        # one build is not duplicated work: the target's macro metadata carries
        # types from its instance while the generated dispatcher supplies
        # `Python` and the traits from the other, so nothing that uses the
        # dispatcher builds.
        registry = (; version = "0.29.2",
                    source = "registry+https://github.com/rust-lang/crates.io-index",
                    dir = "/registry/pyo3-0.29.2")
        toml = join(RustCall._pyo3_alias_toml(registry), "\n")
        @test occursin("version = \"=0.29.2\"", toml)
        @test !occursin("path =", toml)

        # A path dependency is named by the directory Cargo resolved.
        path_dep = (; version = "0.29.2", source = "", dir = "/vendor/pyo3")
        toml = join(RustCall._pyo3_alias_toml(path_dep), "\n")
        @test occursin("path = \"/vendor/pyo3\"", toml)
        @test !occursin("version =", toml)

        # A git dependency reproduces Cargo's source *exactly*, selector and
        # all. Turning `?branch=main` into `rev = <the resolved commit>` looks
        # like a tighter pin and is in fact a different source ID — Cargo would
        # build a second pyo3, which is the failure this is here to prevent
        # (#392 review). The commit needs no repeating: the wrapper is seeded
        # with the target crate's own `Cargo.lock`.
        for (selector, key, value) in (("?branch=main", "branch", "main"),
                                       ("?tag=v0.26.0", "tag", "v0.26.0"),
                                       ("?rev=abc123", "rev", "abc123"))
            git_dep = (; version = "0.30.0",
                       source = "git+https://github.com/PyO3/pyo3$(selector)#deadbeefcafe",
                       dir = "/git/pyo3")
            toml = join(RustCall._pyo3_alias_toml(git_dep), "\n")
            @test occursin("git = \"https://github.com/PyO3/pyo3\"", toml)
            @test occursin("$(key) = \"$(value)\"", toml)
            @test !occursin("version =", toml)
        end
        # No selector: the default branch, and nothing to reproduce.
        git_dep = (; version = "0.30.0",
                   source = "git+https://github.com/PyO3/pyo3#deadbeefcafe",
                   dir = "/git/pyo3")
        toml = join(RustCall._pyo3_alias_toml(git_dep), "\n")
        @test occursin("git = \"https://github.com/PyO3/pyo3\"", toml)
        @test !occursin("rev =", toml)
        @test !occursin("branch =", toml)

        # A URL that merely *starts* with a crates.io index is a different
        # registry, and taking it for crates.io would alias by bare version —
        # the second-instance failure again (#392 review). Compared for
        # equality, not prefix.
        mirror = (; version = "0.29.2",
                  source = "registry+https://github.com/rust-lang/crates.io-index-mirror",
                  dir = "/mirror/pyo3")
        @test_throws RustCall.RustError RustCall._pyo3_alias_toml(mirror)

        # A registry that is not crates.io cannot be named in a generated
        # dependency — `registry = "<name>"` needs a name from the user's Cargo
        # configuration — and a bare version would quietly select crates.io.
        # Refused, rather than built against the wrong package (#392 review).
        other = (; version = "0.29.2", source = "registry+https://example.invalid/index",
                 dir = "/other/pyo3")
        err = try
            RustCall._pyo3_alias_toml(other)
            nothing
        catch e
            e
        end
        @test err isa RustCall.RustError
        @test occursin("example.invalid", sprint(showerror, err))

        # Both crates.io spellings are fine: the sparse protocol has been the
        # default since Cargo 1.70.
        for source in RustCall.CRATES_IO_SOURCES
            sparse = (; version = "0.29.2", source = source, dir = "/registry/pyo3-0.29.2")
            @test occursin("version = \"=0.29.2\"",
                           join(RustCall._pyo3_alias_toml(sparse), "\n"))
        end

        # Every form still aliases the package and keeps the feature set.
        for dep in (registry, path_dep, git_dep)
            toml = join(RustCall._pyo3_alias_toml(dep), "\n")
            @test occursin("[dependencies.rustcall_pyo3]", toml)
            @test occursin("package = \"pyo3\"", toml)
            @test occursin("features = [\"macros\"]", toml)
        end
    end

    @testset "a real path dependency resolves as one (#370)" begin
        # The acceptance criterion asks for a path dependency tested for real.
        # Rather than vendor pyo3 into the repository, this points a crate at
        # the copy Cargo already unpacked into its registry source cache: a
        # genuine `path =` dependency on a genuine pyo3.
        candidates = String[]
        registry_src = joinpath(homedir(), ".cargo", "registry", "src")
        if isdir(registry_src)
            for index in readdir(registry_src; join = true), entry in readdir(index; join = true)
                occursin(r"^pyo3-\d", basename(entry)) && isdir(entry) &&
                    push!(candidates, entry)
            end
        end
        if isempty(candidates)
            @info "Skipping the real path-dependency check: no unpacked pyo3 in the registry cache"
            @test_skip "needs an unpacked pyo3"
        else
            vendored = last(sort!(candidates))
            root = mktempdir()
            try
                write(joinpath(root, "Cargo.toml"), """
                [package]
                name = "pyo3_path_probe"
                version = "0.1.0"
                edition = "2021"

                [dependencies]
                pyo3 = { path = "$(RustCall.escape_toml_string(vendored))", default-features = false, features = ["macros"] }
                """)
                mkpath(joinpath(root, "src"))
                write(joinpath(root, "src", "lib.rs"), "")
                plan = RustCall.pyo3_link_plan(root)
                dep = RustCall._resolved_pyo3_dependency(root, plan)
                # Cargo reports a path dependency with no source, and that is
                # exactly what has to reach the alias.
                @test dep.source == ""
                @test realpath(dep.dir) == realpath(vendored)
                toml = join(RustCall._pyo3_alias_toml(dep), "\n")
                @test occursin("path =", toml)
                @test !occursin("version =", toml)
            finally
                rm(root; force = true, recursive = true)
            end
        end
    end

    @testset "pyo3 metadata runs in the crate's config scope (#392 review)" begin
        # Cargo finds `.cargo/config.toml` by walking up from its *working
        # directory*; `--manifest-path` does not move that root. The cfg probe
        # and the wrapper build both run beneath the target crate so its
        # configuration applies, and this resolution has to agree with them —
        # otherwise a crate whose config replaces a source or names a private
        # registry resolves differently here, or not at all, and is refused for
        # having no identifiable pyo3.
        #
        # The marker is a source replacement pointing at a directory that does
        # not exist: Cargo honours it only when it reads the config, so the call
        # fails loudly from inside the crate and would quietly succeed from
        # anywhere else.
        root = mktempdir()
        try
            mkpath(joinpath(root, "src"))
            mkpath(joinpath(root, ".cargo"))
            write(joinpath(root, "Cargo.toml"), """
            [package]
            name = "pyo3_config_probe"
            version = "0.1.0"
            edition = "2021"

            [dependencies]
            pyo3 = { version = "0.26", default-features = false, features = ["macros"] }
            """)
            write(joinpath(root, "src", "lib.rs"), "")
            write(joinpath(root, ".cargo", "config.toml"), """
            [source.crates-io]
            replace-with = "rustcall-test-missing"

            [source.rustcall-test-missing]
            directory = "$(RustCall.escape_toml_string(joinpath(root, "no-such-vendor")))"
            """)
            plan = RustCall.PyO3LinkPlan(:python_free, String[], "", "test")
            # Read from inside the crate, the replacement applies and there is
            # no vendor directory, so nothing resolves. That is the *positive*
            # signal that the config was read at all.
            @test isempty(RustCall._resolved_pyo3_dependency(root, plan).version)

            # Control: the identical crate without the config resolves normally
            # wherever a fresh pyo3 can be resolved at all. Skipped offline.
            plainroot = mktempdir()
            try
                cp(joinpath(root, "Cargo.toml"), joinpath(plainroot, "Cargo.toml"))
                mkpath(joinpath(plainroot, "src"))
                write(joinpath(plainroot, "src", "lib.rs"), "")
                control = RustCall._resolved_pyo3_dependency(plainroot, plan)
                if isempty(control.version)
                    @info "Skipping the config-scope control: no fresh pyo3 resolves here"
                    @test_skip "needs a resolvable pyo3"
                else
                    @test startswith(control.version, "0.26")
                end
            finally
                rm(plainroot; force = true, recursive = true)
            end
        finally
            rm(root; force = true, recursive = true)
        end
    end

    @testset "a field accessor comes back when its taker is refused (#392 review)" begin
        # A symbol collision *erases* a field's accessors rather than leaving a
        # skip reason on them, so there is nothing to re-derive from when the
        # entry that took the name is later refused by the generator. The
        # original has to be remembered at the moment it is cleared.
        wrapped = code -> begin
            dir = mktempdir()
            try
                mkpath(joinpath(dir, "src"))
                write(joinpath(dir, "src", "lib.rs"), code)
                RustCall.wrap_crate([joinpath(dir, "src", "lib.rs")]; crate_name = "probe")
            finally
                rm(dir; force = true, recursive = true)
            end
        end
        field_of = source -> begin
            class = only(st for st in source.manifest["structs"]
                         if get(st, "name", "") == "C")
            only(f for f in get(class, "fields", []) if get(f, "name", "") == "x")
        end

        # `C_get_x` wants `rustcall_C_get_x`, which is also the getter of `C.x`.
        # The free function claims it first — and is then refused for its
        # `Vec<i32>` argument, so the getter is valid again.
        refused = wrapped("""
        use pyo3::prelude::*;

        #[pyclass]
        pub struct C { #[pyo3(get)] pub x: i32 }

        #[allow(non_snake_case)]
        #[pyfunction]
        #[pyo3(signature = (v = vec![]))]
        pub fn C_get_x(v: Vec<i32>) -> i32 { v.len() as i32 }
        """)
        fn_reason = only(String(get(f, "skip_reason", ""))
                         for f in refused.manifest["functions"]
                         if get(f, "name", "") == "C_get_x")
        @test startswith(fn_reason, "unsupported_arg")
        field = field_of(refused)
        @test String(get(field, "getter", "")) == "rustcall_C_get_x"
        @test get(field, "ffi_compatible", false)

        # The converse: a taker the generator *does* emit keeps the name, and
        # the accessor stays cleared. Restoring must not undo a live collision.
        emitted = wrapped("""
        use pyo3::prelude::*;

        #[pyclass]
        pub struct C { #[pyo3(get)] pub x: i32 }

        #[allow(non_snake_case)]
        #[pyfunction]
        pub fn C_get_x(v: i32) -> i32 { v }
        """)
        fn_reason = only(String(get(f, "skip_reason", ""))
                         for f in emitted.manifest["functions"]
                         if get(f, "name", "") == "C_get_x")
        @test fn_reason == ""
        field = field_of(emitted)
        @test String(get(field, "getter", "")) == ""
        @test !get(field, "ffi_compatible", false)
    end

    @testset "several refused entries do not trap a valid one (#392 review)" begin
        # The relowering loop drops an entry from the report when *it* was the
        # analysis's own loser, so that it is reconsidered. A generator refusal
        # must survive that: several mutually colliding entries the generator
        # refuses have to clear out of the way of a valid one behind them,
        # rather than taking turns owning the name until the bound runs out.
        wrapped = code -> begin
            dir = mktempdir()
            try
                mkpath(joinpath(dir, "src"))
                write(joinpath(dir, "src", "lib.rs"), code)
                RustCall.wrap_crate([joinpath(dir, "src", "lib.rs")]; crate_name = "probe")
            finally
                rm(dir; force = true, recursive = true)
            end
        end

        # A panic slot is the symbol upper-cased, so every case variant of one
        # name wants the same one. Two refused, one valid behind them.
        source = wrapped("""
        use pyo3::prelude::*;

        #[pyfunction]
        #[pyo3(signature = (v = vec![]))]
        pub fn foo(v: Vec<i32>) -> i32 { v.len() as i32 }

        #[allow(non_snake_case)]
        #[pyfunction]
        #[pyo3(signature = (v = vec![]))]
        pub fn FOO(v: Vec<i32>) -> i32 { v.len() as i32 }

        #[allow(non_snake_case)]
        #[pyfunction]
        pub fn Foo(x: i32) -> i32 { x }
        """)
        by_name = Dict(String(get(f, "name", "")) => String(get(f, "skip_reason", ""))
                       for f in source.manifest["functions"])
        @test startswith(by_name["foo"], "unsupported_arg")
        @test startswith(by_name["FOO"], "unsupported_arg")
        @test by_name["Foo"] == ""

        # The same on a class, with four refused ahead of the valid one — each
        # pass can only release one, so this needs the loop to keep going *and*
        # to remember every refusal it has already been told about.
        source = wrapped("""
        use pyo3::prelude::*;

        #[pyclass]
        pub struct C { pub v: i32 }

        #[allow(non_snake_case)]
        #[pymethods]
        impl C {
            #[new]
            pub fn new() -> Self { C { v: 0 } }
            pub fn abc(&self, v: Vec<i32>) -> i32 { v.len() as i32 }
            pub fn abC(&self, v: Vec<i32>) -> i32 { v.len() as i32 }
            pub fn aBc(&self, v: Vec<i32>) -> i32 { v.len() as i32 }
            pub fn aBC(&self, v: Vec<i32>) -> i32 { v.len() as i32 }
            pub fn Abc(&self, x: i32) -> i32 { x }
        }
        """)
        class = only(st for st in source.manifest["structs"]
                     if get(st, "name", "") == "C")
        @test String(get(class, "skip_reason", "")) == ""
        methods = Dict(String(get(m, "name", "")) => String(get(m, "skip_reason", ""))
                       for m in get(class, "methods", []))
        for refused in ("abc", "abC", "aBc", "aBC")
            @test startswith(methods[refused], "unsupported_arg")
        end
        @test methods["Abc"] == ""
    end

    @testset "a refused wrapper build leaves no project behind (#392 review)" begin
        # Writing the wrapper's manifest can refuse outright — a pyo3 older
        # than the dispatcher needs, or one from a registry the alias cannot
        # name. Those are expected outcomes, and the project directory
        # `_wrapper_shaped_project` has already created must go with them
        # rather than accumulating under the crate's target directory for the
        # life of the process.
        root = mktempdir()
        try
            mkpath(joinpath(root, "src"))
            write(joinpath(root, "Cargo.toml"), """
            [package]
            name = "refused_probe"
            version = "0.1.0"
            edition = "2021"
            """)
            write(joinpath(root, "src", "lib.rs"), "")
            info = RustCall.CrateInfo("refused_probe", root, "0.1.0",
                                      RustCall.DependencySpec[],
                                      RustCall.RustFunctionSignature[],
                                      RustCall.RustStructInfo[], String[])
            plan = RustCall.PyO3LinkPlan(:python_free, String[], "", "test")
            # `uses_python_dispatch` with no resolvable pyo3 is the refusal: the
            # wrapper needs the dispatcher and Cargo names no direct pyo3.
            source = RustCall.WrapperCrateSource("refused_probe", "", Dict{String, Any}(),
                                                 String[], true)
            parent = joinpath(RustCall.crate_target_directory(root, :pyo3_wrapper),
                              "rustcall-pyo3-wrapper")
            @test_throws RustCall.RustError RustCall._build_pyo3_wrapper_project(
                info, plan, source, String[], true, "deadbeef"^8, false)
            # The parent may exist; what must not survive is a project tree.
            leftovers = isdir(parent) ?
                filter(startswith("project_"), readdir(parent)) : String[]
            @test isempty(leftovers)
            @test !isdir(joinpath(root, "target"))
        finally
            rm(root; force = true, recursive = true)
        end
    end


end
