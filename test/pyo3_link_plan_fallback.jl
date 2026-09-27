# Component tests loaded by test_pyo3_link_plan.jl.

@testset "PyO3 link plan: conservative fallback" begin
    @testset "conservative fallback: no pyo3 declared" begin
        plan = RustCall._pyo3_conservative_plan(_manifest("""
        [package]
        name = "plain"
        version = "0.1.0"
        """))
        @test plan.mode === :python_free
        @test plan.resolved == false
        @test occursin("no pyo3 dependency", plan.reason)
        @test RustCall.pyo3_link_rustflags(plan) == String[]
    end

    @testset "conservative fallback: extension-module cannot be loaded" begin
        for text in ("""
                     [package]
                     name = "ext"
                     version = "0.1.0"
                     [dependencies]
                     pyo3 = { version = "0.29", features = ["extension-module"] }
                     """,
                     # Renamed dependency: matched on `package`, and the advice
                     # names the key the crate actually uses.
                     """
                     [package]
                     name = "ext_renamed"
                     version = "0.1.0"
                     [dependencies]
                     python = { package = "pyo3", version = "0.29", features = ["extension-module"] }
                     """,
                     # Behind a target table, which the fallback does not try to
                     # evaluate: any declaration counts.
                     """
                     [package]
                     name = "ext_target"
                     version = "0.1.0"
                     [target.'cfg(windows)'.dependencies]
                     pyo3 = { version = "0.29", features = ["extension-module"] }
                     """)
            plan = RustCall._pyo3_conservative_plan(_manifest(text))
            @test occursin("conservative", plan.reason)
            if Sys.iswindows()
                # A DLL resolves every import at link time, so pyo3 links the
                # interpreter's import library there whether or not the feature
                # is on, and the wrapper is an ordinary `:link_libpython` build
                # (#294 review). Only Unix leaves the symbols undefined.
                @test plan.mode === :link_libpython
                @test occursin("On Windows pyo3 still links", plan.reason)
            else
                @test plan.mode === :unlinkable
                @test occursin("extension-module", plan.reason)
                @test_throws RustCall.RustError RustCall.pyo3_link_rustflags(plan)
            end
        end
        # The advice names the key the crate actually uses -- only on the Unix
        # path, which is the one that has to explain why it refused.
        if !Sys.iswindows()
            @test occursin("[dependencies.python]",
                           RustCall._pyo3_conservative_plan(_manifest("""
                           [package]
                           name = "ext_renamed"
                           version = "0.1.0"
                           [dependencies]
                           python = { package = "pyo3", version = "0.29", features = ["extension-module"] }
                           """)).reason)
        end
    end

    @testset "conservative fallback: any other pyo3 links libpython" begin
        # Without Cargo nothing here can show that an *optional* pyo3 is off in
        # the build the wrapper would make, so the fallback does not claim it.
        for text in ("""
                     [package]
                     name = "mandatory"
                     version = "0.1.0"
                     [dependencies]
                     pyo3 = { version = "0.29", default-features = false, features = ["macros"] }
                     """,
                     """
                     [package]
                     name = "optional"
                     version = "0.1.0"
                     [dependencies]
                     pyo3 = { version = "0.29", optional = true }
                     [features]
                     default = []
                     python = ["dep:pyo3"]
                     """)
            plan = RustCall._pyo3_conservative_plan(_manifest(text))
            @test plan.mode === :link_libpython
            @test occursin("conservative", plan.reason)
        end
    end

    @testset "conservative fallback: a skipped resolution says so (#425)" begin
        # `scan_report(...; resolve = false)` uses the same declaration-only
        # reading, but the reason must not blame a Cargo run that never happened.
        plan = RustCall._pyo3_conservative_plan(_manifest("""
        [package]
        name = "mandatory"
        version = "0.1.0"
        [dependencies]
        pyo3 = "0.29"
        """);
        resolution = :skipped)
        @test plan.resolved == false
        @test plan.mode === :link_libpython
        @test plan.cfg_text == ""
        @test occursin("resolve = false", plan.reason)
        @test occursin("conservative", plan.reason)
        @test !occursin("Cargo could not resolve", plan.reason)
    end

    @testset "link flags and the dependency entry" begin
        plan = RustCall._pyo3_conservative_plan(_manifest("""
        [package]
        name = "mandatory"
        version = "0.1.0"
        [dependencies]
        pyo3 = "0.29"
        """))
        @test plan.mode === :link_libpython

        mktempdir() do libdir
            withenv("RUSTCALL_PYTHON_LIBDIR" => libdir) do
                located = RustCall._pyo3_conservative_plan(_manifest("""
                [package]
                name = "mandatory"
                version = "0.1.0"
                [dependencies]
                pyo3 = "0.29"
                """))
                @test located.rpath == libdir
                flags = RustCall.pyo3_link_rustflags(located)
                @test "native=$(libdir)" in flags
                if Sys.iswindows()
                    # Windows has no rpath: the loader finds a DLL through the
                    # executable's directory and PATH, and `link.exe` rejects
                    # `-Wl,-rpath` outright (#294 review).
                    @test flags == ["-L", "native=$(libdir)"]
                else
                    @test any(f -> occursin("rpath,$(libdir)", f), flags)
                end
            end
            withenv("RUSTCALL_PYTHON_LIBDIR" => joinpath(libdir, "nope")) do
                missing_plan = RustCall._pyo3_conservative_plan(_manifest("""
                [package]
                name = "mandatory"
                version = "0.1.0"
                [dependencies]
                pyo3 = "0.29"
                """))
                @test missing_plan.rpath == ""
                @test_throws RustCall.RustError RustCall.pyo3_link_rustflags(missing_plan)
            end
        end

        # `default-features = false` belongs in the wrapper's dependency entry:
        # the `cargo build --no-default-features` flag applies to the package
        # being built, not to a dependency's defaults.
        off = RustCall.PyO3LinkPlan(:python_free, ["--no-default-features"], "", "test", false;
                                    crate_features = ["a", "b"])
        entry = RustCall.pyo3_dependency_toml(off, "target_crate", "/tmp/x")
        @test occursin("[dependencies.target_crate]", entry)
        @test occursin("default-features = false", entry)
        @test occursin("features = [\"a\", \"b\"]", entry)

        on = RustCall.PyO3LinkPlan(:python_free, String[], "", "test", true)
        @test !occursin("default-features", RustCall.pyo3_dependency_toml(on, "t", "/tmp/x"))
    end

    @testset "the interpreter and the library directory come from one source (#307 review)" begin
        mktempdir() do libdir
            fake = joinpath(libdir, "not-a-python")
            manifest = _manifest("""
            [package]
            name = "mandatory"
            version = "0.1.0"
            [dependencies]
            pyo3 = "0.29"
            """)
            # An explicit `PYO3_PYTHON` is the interpreter, never replaced by
            # the first `python3` on PATH; with the directory override too, the
            # pair is exactly what the caller said, and the plan carries both.
            withenv("PYO3_PYTHON" => fake, "RUSTCALL_PYTHON_LIBDIR" => libdir) do
                # A fake interpreter cannot report what it is: no fingerprint.
                @test RustCall.python_link_source() == (libdir, fake, "")
                plan = RustCall._pyo3_conservative_plan(manifest)
                @test plan.mode === :link_libpython
                @test plan.rpath == libdir
                @test plan.interpreter == fake
                @test plan.interpreter_config == ""
            end
            # Without the directory override the directory is asked of the
            # pinned interpreter itself — and one that cannot answer yields no
            # directory, never another interpreter's.
            withenv("PYO3_PYTHON" => fake, "RUSTCALL_PYTHON_LIBDIR" => nothing) do
                @test RustCall.python_link_source() == ("", fake, "")
                @test RustCall.python_library_dir() == ""
            end
            # The directory override alone leaves the interpreter to PATH,
            # which is the one `python3-config` describes — and the fingerprint
            # is that interpreter's own account of itself.
            withenv("PYO3_PYTHON" => nothing, "RUSTCALL_PYTHON_LIBDIR" => libdir) do
                dir, interpreter, config = RustCall.python_link_source()
                @test dir == libdir
                @test RustCall.python_library_dir() == libdir
                @test interpreter == RustCall._python_executable_on_path()
                @test config == RustCall._python_interpreter_fingerprint(interpreter)
                if !isempty(interpreter)
                    # implementation|version|SOABI|LDLIBRARY|LIBDIR|is64|machine
                    # (the machine since #449: a universal macOS Python is one
                    # interpreter with two architectures)
                    @test count('|', config) == 6
                    @test occursin(r"^[A-Za-z]+\|\d+\.\d+", config)
                    @test !isempty(split(config, '|')[end])
                end
            end
            @test RustCall._python_interpreter_fingerprint("") == ""
            # A `:python_free` plan pins no interpreter at all.
            free = RustCall._pyo3_conservative_plan(_manifest("""
            [package]
            name = "plain"
            version = "0.1.0"
            """))
            @test free.mode === :python_free
            @test free.interpreter == ""

            # pyo3's own configuration names the directory — a cross-compile
            # `PYO3_CROSS_LIB_DIR`, or the `lib_dir` of a `PYO3_CONFIG_FILE` —
            # and consults no interpreter, so none is invented for the plan
            # (#307 review). The RustCall-level override still wins.
            withenv("PYO3_CROSS_LIB_DIR" => libdir, "PYO3_PYTHON" => nothing,
                    "PYO3_CONFIG_FILE" => nothing, "RUSTCALL_PYTHON_LIBDIR" => nothing) do
                @test RustCall.python_link_source() == (libdir, "", "")
            end
            cfgfile = joinpath(libdir, "pyo3-build-config.txt")
            write(cfgfile, "implementation=CPython\nversion=3.12\nshared=true\nlib_dir=$(libdir)\n")
            withenv("PYO3_CONFIG_FILE" => cfgfile, "PYO3_CROSS_LIB_DIR" => nothing,
                    "PYO3_PYTHON" => fake, "RUSTCALL_PYTHON_LIBDIR" => nothing) do
                @test RustCall.python_link_source() == (libdir, fake, "")
                plan = RustCall._pyo3_conservative_plan(manifest)
                @test plan.rpath == libdir
                @test plan.interpreter == fake
            end
            withenv("PYO3_CROSS_LIB_DIR" => joinpath(libdir, "elsewhere"),
                    "RUSTCALL_PYTHON_LIBDIR" => libdir, "PYO3_PYTHON" => nothing,
                    "PYO3_CONFIG_FILE" => nothing) do
                @test RustCall.python_link_source()[1] == libdir
            end
            # A config file that names no `lib_dir` decides nothing.
            write(cfgfile, "implementation=CPython\nversion=3.12\n")
            withenv("PYO3_CONFIG_FILE" => cfgfile, "PYO3_CROSS_LIB_DIR" => nothing) do
                @test RustCall._pyo3_configured_lib_dir() == ""
            end
        end
    end

    @testset "the cfg probe runs the crate as a wrapper's dependency (#307 review)" begin
        # A crate's own `[profile.release]` applies when it is the Cargo root
        # and not when it is a wrapper's dependency; the wrapper is what gets
        # built, so the probe has to see the second. This crate's root profile
        # would put `debug_assertions` on and `panic = "abort"` — as a
        # dependency of RustCall's wrapper it gets neither.
        mktempdir() do dir
            _write_crate(dir, """
            [package]
            name = "profiled"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["rlib"]
            [profile.release]
            debug-assertions = true
            panic = "abort"
            """)
            plan = RustCall.pyo3_link_plan(dir)
            if !plan.resolved
                @test_skip "Cargo could not resolve the probe crate"
            else
                @test plan.mode === :python_free
                @test !occursin(r"^debug_assertions$"m, plan.cfg_text)
                @test occursin(r"^panic=\"unwind\"$"m, plan.cfg_text)
                debug = RustCall.pyo3_link_plan(dir; release = false)
                @test debug.resolved
                @test occursin(r"^debug_assertions$"m, debug.cfg_text)
                @test occursin(r"^panic=\"unwind\"$"m, debug.cfg_text)

                # An inherited profile override does not reach the probe
                # either: the wrapper build pins unwinding through its
                # policy, so the probe runs under the same environment
                # (#307 review). The probe is not memoized, so it really runs.
                inherited = withenv("CARGO_PROFILE_RELEASE_PANIC" => "abort") do
                    RustCall.pyo3_link_plan(dir)
                end
                @test inherited.resolved
                @test occursin(r"^panic=\"unwind\"$"m, inherited.cfg_text)
                @test !occursin(r"^panic=\"abort\"$"m, inherited.cfg_text)
            end
        end
    end

    @testset "a workspace member's probe is a root of its own (#307 review)" begin
        # Under `<member>/target/` Cargo climbs to the ancestor workspace and
        # rejects a generated crate that is not one of its members — unless the
        # generated manifest declares an empty `[workspace]`. A member's
        # lockfile and `[patch]` live at the workspace root, and that is where
        # they are taken from.
        mktempdir() do ws
            # Root-only inputs: a `[patch]` and a lockfile at the workspace
            # root (never built, so the patch may name nothing).
            write(joinpath(ws, "Cargo.toml"), """
            [workspace]
            members = ["member"]
            exclude = ["standalone"]
            [patch.crates-io]
            foo = { path = "vendor/foo" }
            """)
            write(joinpath(ws, "Cargo.lock"), "# the workspace's lockfile\n")
            member = _write_crate(joinpath(ws, "member"), """
            [package]
            name = "member"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["rlib"]
            """)
            @test RustCall._cargo_root_dir(member) == ws
            patched = RustCall._root_patch_toml(member)
            @test occursin("[patch.crates-io", patched)
            @test occursin("vendor", patched)
            @test !occursin(joinpath("member", "vendor"), patched)
            project, lease = RustCall._wrapper_shaped_project(member, "rustcall-pyo3-test")
            @test read(joinpath(project, "Cargo.lock"), String) == "# the workspace's lockfile\n"
            RustCall._remove_shaped_project(project, lease)
            @test occursin(r"^\[workspace\]$"m,
                           RustCall._probe_cargo_toml("member", member, String[], true))

            # A package the workspace lists in `exclude` is its own root: not
            # a member, so Cargo gives it none of the root's inputs — and
            # neither does RustCall (#307 review).
            standalone = _write_crate(joinpath(ws, "standalone"), """
            [package]
            name = "standalone"
            version = "0.1.0"
            edition = "2021"
            """)
            @test RustCall._workspace_root_dir(standalone) === nothing
            @test RustCall._cargo_root_dir(standalone) == abspath(standalone)
            @test RustCall._root_patch_toml(standalone) == ""
            project, lease = RustCall._wrapper_shaped_project(standalone, "rustcall-pyo3-test")
            @test !isfile(joinpath(project, "Cargo.lock"))
            RustCall._remove_shaped_project(project, lease)

            # ... but an explicit `members` listing wins over `exclude`, as it
            # does in Cargo (`is_excluded` is "excluded and not an explicit
            # member"): `members = ["crates/foo/bar"]` next to
            # `exclude = ["crates/foo"]` keeps `bar` a member, while its
            # unlisted sibling under `crates/foo` is excluded, and a glob
            # member rescues nothing because Cargo compares the raw list
            # (#307 review).
            table = Dict{String, Any}("members" => ["crates/foo/bar", "globbed/*"],
                                      "exclude" => ["crates/foo", "globbed"])
            @test !RustCall._workspace_excludes(table, ws, joinpath(ws, "crates", "foo", "bar"))
            @test !RustCall._workspace_excludes(table, ws, joinpath(ws, "crates", "foo", "bar", "deeper"))
            @test RustCall._workspace_excludes(table, ws, joinpath(ws, "crates", "foo", "other"))
            @test RustCall._workspace_excludes(table, ws, joinpath(ws, "crates", "foo"))
            @test RustCall._workspace_excludes(table, ws, joinpath(ws, "globbed", "x"))
            @test !RustCall._workspace_excludes(table, ws, joinpath(ws, "crates", "elsewhere"))
            # End to end: the listed descendant of an excluded directory finds
            # the workspace root and its inputs.
            nested_ws = mktempdir()
            write(joinpath(nested_ws, "Cargo.toml"), """
            [workspace]
            members = ["crates/foo/bar"]
            exclude = ["crates/foo"]
            """)
            write(joinpath(nested_ws, "Cargo.lock"), "# nested lockfile\n")
            bar = _write_crate(joinpath(nested_ws, "crates", "foo", "bar"), """
            [package]
            name = "bar"
            version = "0.1.0"
            edition = "2021"
            """)
            other = _write_crate(joinpath(nested_ws, "crates", "foo", "other"), """
            [package]
            name = "other"
            version = "0.1.0"
            edition = "2021"
            """)
            @test RustCall._workspace_root_dir(bar) == nested_ws
            @test RustCall._cargo_root_dir(bar) == nested_ws
            @test RustCall._workspace_root_dir(other) === nothing
            rm(nested_ws; recursive = true, force = true)

            # The root's manifest and lockfile are inputs of a member's
            # artifact identity: a change there that touches no file of the
            # member still rebuilds (#307 review, #278).
            info = RustCall.scan_crate(member)
            key_before = RustCall.compute_crate_hash(info)
            write(joinpath(ws, "Cargo.lock"), "# the workspace's lockfile, revised\n")
            RustCall._artifact_reset_digest_caches!()
            key_lock = RustCall.compute_crate_hash(info)
            @test key_lock != key_before
            write(joinpath(ws, "Cargo.toml"),
                  read(joinpath(ws, "Cargo.toml"), String) *
                  "\n[workspace.dependencies]\nserde = \"1\"\n")
            RustCall._artifact_reset_digest_caches!()
            @test RustCall.compute_crate_hash(info) != key_lock
            # ... while the excluded package's identity does not move with the
            # workspace it is not part of.
            standalone_info = RustCall.scan_crate(standalone)
            key_standalone = RustCall.compute_crate_hash(standalone_info)
            write(joinpath(ws, "Cargo.lock"), "# revised again\n")
            RustCall._artifact_reset_digest_caches!()
            @test RustCall.compute_crate_hash(standalone_info) == key_standalone
        end

        # A PyO3 crate whose requested build exposes nothing falls back to the
        # plain path — under the resolved configuration, not the lenient scan:
        # a `#[julia]` item the selected features disable must not be bound.
        mktempdir() do dir
            _write_crate(dir, """
            [package]
            name = "gated_julia"
            version = "0.1.0"
            edition = "2021"
            [features]
            default = []
            extra = []
            """)
            write(joinpath(dir, "src", "lib.rs"), """
            #[julia]
            pub fn plain_fn() -> i32 { 2 }

            #[cfg(feature = "extra")]
            #[julia]
            pub fn extra_fn() -> i32 { 1 }
            """)
            lenient = RustCall.scan_crate(dir)
            @test Set(f.name for f in lenient.julia_functions) == Set(["plain_fn", "extra_fn"])
            # The fallback binds through `_plain_scan_info`, like any plain
            # crate: probed with the shape of its build (here a wrapper's
            # dependency — no cdylib), under the requested features. `extra`
            # off drops `extra_fn`; `extra` on keeps it.
            if !RustCall.check_rustc_available()
                @test_skip "cargo is required to probe the crate"
            else
                off = RustCall._plain_scan_info(dir, lenient, String[], true, true)
                @test Set(f.name for f in off.julia_functions) == Set(["plain_fn"])
                on = RustCall._plain_scan_info(dir, lenient, ["extra"], true, true)
                @test Set(f.name for f in on.julia_functions) == Set(["plain_fn", "extra_fn"])
            end
        end
        # And the probe really resolves from inside a workspace: without the
        # `[workspace]` line Cargo refuses it, the plan comes back unresolved,
        # and every `#[cfg]` item is refused.
        mktempdir() do ws
            write(joinpath(ws, "Cargo.toml"), """
            [workspace]
            members = ["member"]
            """)
            member = _write_crate(joinpath(ws, "member"), """
            [package]
            name = "member"
            version = "0.1.0"
            edition = "2021"
            [lib]
            crate-type = ["rlib"]
            """)
            plan = RustCall.pyo3_link_plan(member)
            if !plan.resolved
                @test_skip "Cargo could not resolve the workspace member"
            else
                @test plan.mode === :python_free
                @test occursin("target_pointer_width", plan.cfg_text)
            end
        end
    end

    @testset "a missing Cargo.toml is an error, not a mode" begin
        mktempdir() do dir
            @test_throws RustCall.RustError RustCall.pyo3_link_plan(dir)
            @test_throws RustCall.RustError RustCall.pyo3_feature_candidates(dir)
            # `resolve = false` needs the manifest too: no Cargo, but still a crate.
            @test_throws RustCall.RustError RustCall.scan_report(dir; resolve = false)
        end
    end

    @testset "feature flags are spelled the way Cargo takes them" begin
        @test RustCall._pyo3_feature_flags(String[], true) == String[]
        @test RustCall._pyo3_feature_flags(String[], false) == ["--no-default-features"]
        @test RustCall._pyo3_feature_flags(["a"], true) == ["--features", "a"]
        @test RustCall._pyo3_feature_flags(["a", "b"], false) ==
              ["--no-default-features", "--features", "a,b"]
    end

    @testset "skip reasons have explanations" begin
        @test RustCall.pyo3_skip_explanation("") == ""
        @test occursin("E0603", RustCall.pyo3_skip_explanation("not_public"))
        text = RustCall.pyo3_skip_explanation("pyo3_type:Python<'_>")
        @test occursin("interpreter", text)
        @test occursin("Python<'_>", text)
        @test occursin("#300", RustCall.pyo3_skip_explanation("symbol_collision:a::run"))
        # An unknown reason from a newer extractor is passed through, never
        # rendered as an empty explanation.
        @test RustCall.pyo3_skip_explanation("brand_new_reason") == "brand_new_reason"
    end


end
