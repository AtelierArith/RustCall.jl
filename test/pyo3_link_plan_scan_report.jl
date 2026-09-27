# Component tests loaded by test_pyo3_link_plan.jl.

@testset "PyO3 link plan: scan reports" begin
    @testset "a refused entry does not keep a valid name (#392 review)" begin
        # The symbol table reserves every arity an entry *will* emit, and it
        # runs in the scan — before the generator has had the chance to refuse
        # that entry. A reservation left standing for an entry that then emits
        # nothing used to cost a valid item its own name.
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
        # A defaulted entry the generator emits appears once per arity, all
        # under the same `name`, so this collects rather than picking one.
        reasons = (source, name) -> unique!(String[String(get(f, "skip_reason", ""))
                                                   for f in source.manifest["functions"]
                                                   if get(f, "name", "") == name])
        reason = (source, name) -> only(reasons(source, name))

        # `foo` is refused for its `Vec<i32>` argument, so `rustcall_foo__default_1`
        # is a symbol nothing defines and `foo__default_1` may have it.
        source = wrapped("""
        use pyo3::prelude::*;

        #[pyfunction]
        #[pyo3(signature = (a, values = vec![]))]
        pub fn foo(a: i32, values: Vec<i32>) -> i32 { a + values.len() as i32 }

        #[pyfunction]
        pub fn foo__default_1(x: i32) -> i32 { x }
        """)
        @test startswith(reason(source, "foo"), "unsupported_arg")
        @test reason(source, "foo__default_1") == ""

        # The converse still holds: when the defaulted entry *is* emitted, the
        # arity is a real symbol and the lookalike is the one that gives way.
        source = wrapped("""
        use pyo3::prelude::*;

        #[pyfunction]
        #[pyo3(signature = (a, b = 1))]
        pub fn foo(a: i32, b: i32) -> i32 { a + b }

        #[pyfunction]
        pub fn foo__default_1(x: i32) -> i32 { x }
        """)
        # Both arities are emitted, so both claim, and the lookalike gives way.
        @test reasons(source, "foo") == [""]
        @test count(f -> get(f, "name", "") == "foo", source.manifest["functions"]) == 2
        @test startswith(reason(source, "foo__default_1"), "symbol_collision")

        # And a collision between two entries the generator accepts is decided
        # exactly as before — the analysis must not read "lost a collision" as
        # "the generator refuses it" and hand the symbol back.
        source = wrapped("""
        use pyo3::prelude::*;

        #[pyfunction]
        pub fn add(a: i32, b: i32) -> i32 { a + b }

        #[pyfunction]
        pub fn add_take_panic() -> i32 { 0 }
        """)
        @test reason(source, "add") == ""
        @test startswith(reason(source, "add_take_panic"), "symbol_collision")
    end

    @testset "a target crate named like a wrapper's own dependency (#392 review)" begin
        # Nothing reserves a crate *name*: the crate being wrapped is the
        # user's, and it may be called `rustcall_pyo3` or
        # `rustcall_julia_macros` — the two names the generated wrapper spends
        # on itself. The dependency is renamed rather than written twice.
        plain = Dict{String, Any}()
        @test RustCall.wrapper_target_identifier("some_crate", plain) == ("some_crate", false)
        @test RustCall.wrapper_target_identifier("some-crate", plain) == ("some_crate", false)
        for reserved in RustCall.WRAPPER_RESERVED_CRATE_NAMES
            identifier, renamed = RustCall.wrapper_target_identifier(reserved, plain)
            @test renamed
            @test identifier == "rustcall_target_" * reserved
            @test !(identifier in RustCall.WRAPPER_RESERVED_CRATE_NAMES)
        end
        # A `[lib] name` that spells a reserved name counts too: that is the
        # identifier the generated Rust would use.
        lib_named = Dict{String, Any}("lib" => Dict{String, Any}("name" => "rustcall_pyo3"))
        identifier, renamed = RustCall.wrapper_target_identifier("innocent", lib_named)
        @test renamed
        @test identifier == "rustcall_target_rustcall_pyo3"

        # The generated manifest keeps one table per name, and the renamed one
        # names the real package.
        info = RustCall.CrateInfo("rustcall_pyo3", "/tmp/does-not-exist", "0.1.0",
                                  RustCall.DependencySpec[],
                                  RustCall.RustFunctionSignature[],
                                  RustCall.RustStructInfo[], String[])
        plan = RustCall.PyO3LinkPlan(:python_free, String[], "", "test")
        toml = RustCall.generate_pyo3_wrapper_cargo_toml(
            info, plan; wrapper_name = "w", python_dispatch = true,
            target_identifier = "rustcall_target_rustcall_pyo3", target_renamed = true,
            pyo3_dependency = (; version = "0.26.0",
                               source = first(RustCall.CRATES_IO_SOURCES),
                               dir = "/registry/pyo3-0.26.0"))
        # A crate that needs no rename keeps the *package* name as the table
        # key — Cargo keys on the package, not on the crate identifier, and a
        # `-` in the name or a `[lib] name` of its own makes the two differ.
        plain_info = RustCall.CrateInfo("builtin-api", "/tmp/does-not-exist", "0.1.0",
                                        RustCall.DependencySpec[],
                                        RustCall.RustFunctionSignature[],
                                        RustCall.RustStructInfo[], String[])
        plain_toml = RustCall.generate_pyo3_wrapper_cargo_toml(
            plain_info, plan; wrapper_name = "w",
            target_identifier = "builtin_api", target_renamed = false)
        @test occursin("[dependencies.builtin-api]", plain_toml)
        @test !occursin("package =", plain_toml)

        @test occursin("[dependencies.rustcall_target_rustcall_pyo3]", toml)
        @test occursin("package = \"rustcall_pyo3\"", toml)
        @test count(==("[dependencies.rustcall_pyo3]"), split(toml, "\n")) == 1
    end

    @testset "a live target-conditional pyo3 still resolves (#392 review)" begin
        # `[target.'cfg(...)'.dependencies] pyo3` links exactly like a plain
        # dependency on the platforms whose `cfg` it matches. An earlier fix for
        # the dev/build-dependency case required a null `target` in `dep_kinds`
        # and so discarded these edges outright, and the dispatcher then refused
        # every such crate for want of a version. Cargo prunes the inactive ones
        # itself (`--filter-platform`), so the live edge has to survive.
        probe = table -> begin
            root = mktempdir()
            try
                write(joinpath(root, "Cargo.toml"), """
                [package]
                name = "pyo3_target_probe"
                version = "0.1.0"
                edition = "2021"

                $(table)
                pyo3 = { version = "0.26", default-features = false, features = ["macros"] }
                """)
                mkpath(joinpath(root, "src"))
                write(joinpath(root, "src", "lib.rs"), "")
                return RustCall._resolved_pyo3_dependency(root, RustCall.pyo3_link_plan(root))
            finally
                rm(root; force = true, recursive = true)
            end
        end

        # The control decides whether this environment can resolve a fresh pyo3
        # at all: the offline CI job runs with `CARGO_NET_OFFLINE=true` and an
        # empty `CARGO_HOME` seeded only from `test/fixtures/offline_prefetch`,
        # where a temporary crate asking the registry for a version resolves
        # nothing. `_resolved_pyo3_dependency` fails *closed* — it reports an
        # empty result rather than raising — so without a control an
        # unresolvable environment is indistinguishable from the regression
        # this test exists to catch (#259, #392 review).
        plain = probe("[dependencies]")
        if isempty(plain.version)
            @info "Skipping the target-conditional probe: this environment resolves no fresh pyo3"
            @test_skip "needs a resolvable pyo3"
        else
            # `cfg(any(unix, windows))` is live on every platform the suite runs
            # on, and is still spelled as a target-conditional table — so this
            # asserts the shape, not the host. Whatever the control resolved,
            # the target-conditional form has to resolve the same thing.
            targeted = probe("[target.'cfg(any(unix, windows))'.dependencies]")
            @test targeted == plain
            @test !isempty(targeted.version)
            @test startswith(targeted.version, "0.26")
        end
    end

    @testset "the generator reports dispatcher use, Julia does not guess (#392 review)" begin
        # Julia does not parse Rust (#264), and every proxy is wrong one way or
        # the other: a defaulted callable the generator refused leaves a
        # `python_default` in the manifest with no dispatcher emitted, while a
        # class made Python-owned by exactly such a refused method has a
        # `Py<PyAny>` handle with no emitted default to infer from (#371).
        # Scanning the source is wrong too — `#[pyfunction] fn
        # rustcall_pyo3_status` puts those characters in a symbol. The generator
        # is the only thing that knows, because it is what writes the path.
        wrapped(code) = mktempdir() do dir
            path = joinpath(dir, "lib.rs")
            write(path, code)
            RustCall.wrap_crate([path]; crate_name = "probe")
        end

        direct = wrapped("""
            #[pyfunction]
            pub fn plain(a: i32) -> i32 { a }
            """)
        @test direct.uses_python_dispatch === false

        # A name that merely contains the alias is still not dispatcher use.
        lookalike = wrapped("""
            #[pyfunction]
            pub fn rustcall_pyo3_status() -> i32 { 1 }
            """)
        @test lookalike.uses_python_dispatch === false

        # A defaulted callable does use it.
        defaulted = wrapped("""
            #[pyfunction]
            #[pyo3(signature = (value = 1))]
            pub fn defaulted(value: i32) -> i32 { value }
            """)
        @test defaulted.uses_python_dispatch === true

        # And so does a class made Python-owned by inheritance.
        inherited = wrapped("""
            #[pyclass]
            pub struct Base;
            #[pyclass(extends = Base)]
            pub struct Child { value: i32 }
            #[pymethods]
            impl Child {
                #[new]
                pub fn new() -> (Self, Base) { (Self { value: 1 }, Base) }
            }
            """)
        @test inherited.uses_python_dispatch === true
    end

    @testset "a dispatcher wrapper refuses a pyo3 older than it needs (#370)" begin
        # `Python::initialize` / `Python::attach` arrived in pyo3 0.26 — checked
        # against the `marker.rs` of 0.24, 0.25 and 0.26, not the changelog.
        # Before this the generator happily emitted them and the *wrapper build*
        # failed with rustc errors about code the user never wrote.
        @test RustCall.PYO3_DISPATCHER_MINIMUM == v"0.26"
        for old in ("0.22.3", "0.24.0", "0.25.0", "0.25.1")
            err = try
                RustCall._require_dispatcher_pyo3_version(old, "old_crate")
                nothing
            catch e
                e
            end
            @test err isa RustCall.RustError
            message = sprint(showerror, err)
            # The three things a reader needs: which crate, what it has, and
            # what it would take.
            @test occursin("old_crate", message)
            @test occursin(old, message)
            @test occursin("0.26", message)
            @test occursin("Python::attach", message)
        end
        # The floor itself and anything above it are fine.
        for ok in ("0.26.0", "0.26.1", "0.29.2", "1.0.0")
            @test RustCall._require_dispatcher_pyo3_version(ok, "new_crate") === nothing
        end
        # An unparseable version is not evidence of anything: let the build speak
        # rather than refuse on a guess.
        @test RustCall._require_dispatcher_pyo3_version("", "odd") === nothing
        @test RustCall._require_dispatcher_pyo3_version("not-a-version", "odd") === nothing
    end

    @testset "a plan whose cfg probe failed is not `resolved`" begin
        # `cargo tree` can succeed while `cargo rustc -- --print cfg` fails.
        # Saying `resolved = true` with an empty `cfg_text` made `scan_report`
        # fall back to a lenient scan without ever saying so.
        for (pyo3_features, pyo3_active, expected) in
                ((String[], false, :python_free),
                 (["macros"], true, :link_libpython))
            plan = RustCall._pyo3_unresolved_cfg_plan(".", String[], ["a"],
                                                      pyo3_features, pyo3_active)
            @test plan.resolved == false
            @test plan.cfg_text == ""
            @test plan.mode === expected
            @test plan.crate_features == ["a"]
            @test occursin("--print cfg", plan.reason)
        end
    end

    @testset "scan_report(resolve = false) is a probe-free Phase 1 (#425)" begin
        # The default route asks Cargo to resolve features and runs the wrapper
        # cfg probe, which compiles the crate's whole dependency graph. This
        # opt-out runs no Cargo: the plan is the declaration-only reading and
        # the scan is lenient, so a `#[cfg]`-carrying item is reported rather
        # than decided.
        mktempdir() do dir
            _write_crate(dir, """
            [package]
            name = "probe_free_scan"
            version = "0.1.0"
            edition = "2021"
            [dependencies]
            pyo3 = { version = "0.29", default-features = false, features = ["macros"] }
            [features]
            extra = []
            """)
            write(joinpath(dir, "src", "lib.rs"), """
            #[pyfunction]
            pub fn always(a: i32) -> i32 { a }

            #[cfg(feature = "extra")]
            #[pyfunction]
            pub fn gated(a: i32) -> i32 { a }
            """)
            io = IOBuffer()
            report = RustCall.scan_report(dir; io = io, generate = false, resolve = false)
            text = String(take!(io))
            @test report.plan.resolved == false
            @test report.plan.cfg_text == ""
            @test occursin("resolve = false", report.plan.reason)
            # `pyo3_feature_candidates` is a Cargo resolution per feature: under
            # `resolve = false` there is no Cargo to ask, so the column is empty.
            @test isempty(report.candidates)
            @test occursin("resolution skipped", text)
            names = Set(String(f.name) for f in report.wrappable)
            @test "always" in names
            @test "gated" in names
            # Neither Cargo resolution would have made its project tree under
            # the crate's `target/`; nothing did, so neither directory exists.
            @test !isdir(joinpath(dir, "target", "rustcall-pyo3-probe"))
            @test !isdir(joinpath(dir, "target", "rustcall-pyo3-features"))
            # The empty snapshot is what keeps the lenient scan off Cargo:
            # `_cfg_file_args` passes no arguments and never asks for a snapshot.
            @test isempty(RustCall._cfg_file_args(:lenient; cfg_text = ""))
        end
    end

    @testset "resolve = false reads inherited fields without Cargo (#425 review)" begin
        # A workspace member inheriting `version` / `edition` used to reach
        # `cargo metadata` through `scan_crate`, so the advertised no-Cargo mode
        # still launched Cargo. The manifest read decides both now.
        mktempdir() do ws
            write(joinpath(ws, "Cargo.toml"), """
            [workspace]
            members = ["member"]
            [workspace.package]
            version = "9.9.9"
            edition = "2021"
            """)
            member = _write_crate(joinpath(ws, "member"), """
            [package]
            name = "inheriting"
            version = { workspace = true }
            edition = { workspace = true }
            """)
            toml = RustCall.parse_cargo_toml(joinpath(member, "Cargo.toml"))
            @test RustCall._crate_rust_edition(member, toml; allow_cargo = false) == "2021"
            @test RustCall._package_field(member, toml, "version", "0.1.0";
                                          allow_cargo = false) == "9.9.9"

            io = IOBuffer()
            report = RustCall.scan_report(member; io = io, generate = false, resolve = false)
            @test report.info.name == "inheriting"
            @test report.info.version == "9.9.9"
            @test !isdir(joinpath(member, "target", "rustcall-pyo3-probe"))
        end
    end

    @testset "resolve = false expands inherited workspace dependencies (#425 review)" begin
        # The root renames pyo3 under an alias and the member inherits it with
        # `workspace = true`. A declaration-only reader that saw the unexpanded
        # member manifest would find no `package = "pyo3"` and call the crate
        # `:python_free` though it depends on pyo3.
        mktempdir() do ws
            write(joinpath(ws, "Cargo.toml"), """
            [workspace]
            members = ["member"]
            [workspace.dependencies]
            python = { package = "pyo3", version = "0.29", default-features = false, features = ["macros"] }
            """)
            member = _write_crate(joinpath(ws, "member"), """
            [package]
            name = "aliased"
            version = "0.1.0"
            edition = "2021"
            [dependencies]
            python = { workspace = true }
            """)
            plan = RustCall._pyo3_conservative_plan(RustCall._declaration_manifest(member);
                                                    resolution = :skipped)
            @test plan.mode === :link_libpython
            io = IOBuffer()
            report = RustCall.scan_report(member; io = io, generate = false, resolve = false)
            @test report.plan.mode === :link_libpython

            # A workspace `extension-module` is seen through the alias too.
            write(joinpath(ws, "Cargo.toml"), """
            [workspace]
            members = ["member"]
            [workspace.dependencies]
            python = { package = "pyo3", version = "0.29", features = ["extension-module"] }
            """)
            aliased = RustCall._pyo3_conservative_plan(RustCall._declaration_manifest(member);
                                                       resolution = :skipped)
            if Sys.iswindows()
                @test aliased.mode === :link_libpython
            else
                @test aliased.mode === :unlinkable
            end
        end
    end
end
