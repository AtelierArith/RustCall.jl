# Phase 1.5 of #275: before a wrapper crate is built against a PyO3 crate,
# decide whether it can be linked and loaded at all, and under which features.
#
# The plan asks **Cargo** to resolve the features (`cargo tree -e features`) and
# rustc for the resulting configuration, rather than re-implementing feature
# resolution in Julia. Two layers are tested separately:
#
#   * the conservative fallback, a pure `Cargo.toml` read used when Cargo cannot
#     answer — fast, offline, no toolchain needed;
#   * the resolved path, against the committed example crates, skipped when
#     Cargo cannot resolve them (no cargo, no network for a cold registry).
using RustCall
using Test
using TOML

function _write_crate(dir::AbstractString, cargo_toml::AbstractString)
    mkpath(joinpath(dir, "src"))
    write(joinpath(dir, "Cargo.toml"), cargo_toml)
    write(joinpath(dir, "src", "lib.rs"), "")
    return dir
end

_manifest(text::AbstractString) = TOML.parse(text)

@testset "PyO3 link plan (#275 Phase 1.5)" begin
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
                    # implementation|version|SOABI|LDLIBRARY|LIBDIR|is64
                    @test count('|', config) == 5
                    @test occursin(r"^[A-Za-z]+\|\d+\.\d+", config)
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
                # (#307 review). The memo is cleared so the probe really runs.
                empty!(RustCall._WRAPPER_CFG_TEXT)
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
            project = RustCall._wrapper_shaped_project(member, "rustcall-pyo3-test")
            @test read(joinpath(project, "Cargo.lock"), String) == "# the workspace's lockfile\n"
            rm(project; recursive = true, force = true)
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
            project = RustCall._wrapper_shaped_project(standalone, "rustcall-pyo3-test")
            @test !isfile(joinpath(project, "Cargo.lock"))
            rm(project; recursive = true, force = true)

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

            # The probe's memo is keyed on the same root inputs: a changed
            # root lockfile or manifest is a new probe, not the old answer
            # (#307 review).
            memo_before = RustCall._wrapper_probe_memo_key(member, String[], true, true)
            write(joinpath(ws, "Cargo.lock"), "# revised once more\n")
            @test RustCall._wrapper_probe_memo_key(member, String[], true, true) != memo_before
            memo_lock = RustCall._wrapper_probe_memo_key(member, String[], true, true)
            write(joinpath(ws, "Cargo.toml"),
                  read(joinpath(ws, "Cargo.toml"), String) * "\n# a root manifest edit\n")
            @test RustCall._wrapper_probe_memo_key(member, String[], true, true) != memo_lock
            @test RustCall._wrapper_probe_memo_key(member, String[], true, false) !=
                  RustCall._wrapper_probe_memo_key(member, String[], true, true)

            # ... and on pyo3's own configuration, which `pyo3-build-config`
            # turns into `Py_3_x` cfgs: a different `PYO3_PYTHON`, or the same
            # `PYO3_CONFIG_FILE` path with different contents, is a new probe —
            # the artifact key already moves, the memo must move with it (#307
            # review).
            memo_plain = RustCall._wrapper_probe_memo_key(member, String[], true, true)
            withenv("PYO3_PYTHON" => joinpath(ws, "python3.12")) do
                @test RustCall._wrapper_probe_memo_key(member, String[], true, true) != memo_plain
            end
            config = joinpath(ws, "pyo3-config.txt")
            write(config, "implementation=CPython\nversion=3.12\n")
            withenv("PYO3_CONFIG_FILE" => config) do
                memo_config = RustCall._wrapper_probe_memo_key(member, String[], true, true)
                @test memo_config != memo_plain
                write(config, "implementation=CPython\nversion=3.13\n")
                @test RustCall._wrapper_probe_memo_key(member, String[], true, true) != memo_config
            end
            @test RustCall._wrapper_probe_memo_key(member, String[], true, true) == memo_plain
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
            # The configuration of a build with `extra` off names no such
            # feature, so the strict rescan drops `extra_fn`.
            os = Sys.iswindows() ? "windows" : Sys.isapple() ? "macos" : "linux"
            family = Sys.iswindows() ? "windows" : "unix"
            off = RustCall.PyO3LinkPlan(:python_free, String[], "", "test";
                                        cfg_text = "target_os=\"$(os)\"\n$(family)\n",
                                        resolved = true)
            resolved = RustCall._resolved_plain_info(dir, lenient, off)
            @test Set(f.name for f in resolved.julia_functions) == Set(["plain_fn"])
            # An unresolved plan changes nothing.
            unresolved = RustCall.PyO3LinkPlan(:python_free, String[], "", "test")
            @test RustCall._resolved_plain_info(dir, lenient, unresolved) === lenient
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

    # ------------------------------------------------------------------
    # The resolved path. Needs cargo and a resolvable crate.
    # ------------------------------------------------------------------
    mandatory_crate = joinpath(dirname(@__DIR__), "examples", "sample_crate_pyo3_only")
    optional_crate = joinpath(dirname(@__DIR__), "examples", "sample_crate_pyo3")
    probe = try
        RustCall.pyo3_link_plan(mandatory_crate)
    catch
        nothing
    end

    if probe === nothing || !probe.resolved
        @warn "Cargo could not resolve the example crates; skipping the resolved link-plan tests"
    else
        @testset "resolved: mandatory pyo3 links libpython" begin
            plan = RustCall.pyo3_link_plan(mandatory_crate)
            @test plan.resolved
            @test plan.mode === :link_libpython
            # Cargo's own answer, not a re-implementation of feature resolution.
            @test "macros" in plan.pyo3_features
            @test !("extension-module" in plan.pyo3_features)
            # The configuration the crate scan then runs under.
            @test !isempty(plan.cfg_text)
            @test occursin("target_pointer_width", plan.cfg_text)
        end

        @testset "resolved: the cfg probe follows the requested profile (#307 review)" begin
            # `debug_assertions` is set in a debug build and not in a release
            # one, so a scan under the wrong profile decides a
            # `#[cfg(debug_assertions)]` item the other way round: the plan for
            # `build_release = false` must probe the debug configuration.
            release = RustCall.pyo3_link_plan(mandatory_crate)
            debug = RustCall.pyo3_link_plan(mandatory_crate; release = false)
            @test release.resolved && debug.resolved
            @test !occursin(r"^debug_assertions$"m, release.cfg_text)
            @test occursin(r"^debug_assertions$"m, debug.cfg_text)
            # Everything but the configuration is the same build.
            @test debug.mode === release.mode
            @test debug.pyo3_features == release.pyo3_features
        end

        @testset "resolved: the feature set is the caller's choice" begin
            # `examples/sample_crate_pyo3` has
            # `pyo3 = { optional = true, features = ["extension-module"] }` behind
            # `python = [...]` with `default = []`. Different feature sets are
            # genuinely different builds, and the plan answers for the one asked
            # about rather than hunting for a nicer one.
            default_plan = RustCall.pyo3_link_plan(optional_crate)
            @test default_plan.resolved
            @test default_plan.mode === :python_free
            @test isempty(default_plan.pyo3_features)
            @test occursin("does not resolve pyo3", default_plan.reason)

            with_python = RustCall.pyo3_link_plan(optional_crate; features = ["python"])
            @test with_python.resolved
            @test "extension-module" in with_python.pyo3_features
            @test with_python.feature_flags == ["--features", "python"]
            if Sys.iswindows()
                # See the conservative-fallback testset: `extension-module` is
                # not a blocker on Windows.
                @test with_python.mode === :link_libpython
                @test occursin("On Windows pyo3 still links", with_python.reason)
            else
                @test with_python.mode === :unlinkable
                @test occursin("extension-module", with_python.reason)
                @test occursin("pyo3_feature_candidates", with_python.reason)
            end
        end

        @testset "resolved: which features activate pyo3" begin
            candidates = RustCall.pyo3_feature_candidates(optional_crate)
            @test !isempty(candidates)
            python = only(c for c in candidates if c.feature == "python")
            @test python.activates_pyo3
            # This crate's feature also pulls `extension-module`, which is what
            # makes that build unloadable.
            @test python.extension_module

            # A crate with no `[features]` table has nothing to choose from.
            @test isempty(RustCall.pyo3_feature_candidates(mandatory_crate))
        end

        @testset "resolved: dev-dependencies do not poison the plan" begin
            # A wrapper depends on the target crate's *library*, so the target's
            # dev-dependencies are not in the graph it builds. Reading feature
            # edges without restricting them to normal dependencies would report
            # this crate as unlinkable.
            mktempdir() do dir
                _write_crate(dir, """
                [package]
                name = "dev_ext"
                version = "0.1.0"
                edition = "2021"

                [dependencies]
                pyo3 = { version = "0.29", default-features = false, features = ["macros"] }

                [dev-dependencies]
                pyo3 = { version = "0.29", features = ["extension-module"] }
                """)
                plan = RustCall.pyo3_link_plan(dir)
                if !plan.resolved
                    @warn "Cargo could not resolve the dev-dependency crate; skipping"
                else
                    @test plan.mode === :link_libpython
                    @test !("extension-module" in plan.pyo3_features)
                end
            end
        end
    end

    # ------------------------------------------------------------------
    # From the post-merge review of #294 (PR that landed Phase 1 / 1.5).
    # ------------------------------------------------------------------

    @testset "extension-module is a Unix-only blocker" begin
        # A DLL must resolve every import at link time, so pyo3 links the
        # interpreter's import library on Windows regardless of
        # `extension-module`; the resulting cdylib loads like any other
        # `:link_libpython` build. On Unix the feature leaves libpython's
        # symbols undefined and the cdylib cannot be loaded at all.
        @test RustCall.extension_module_is_linkable() == Sys.iswindows()

        plan = RustCall._pyo3_unresolved_cfg_plan(".", String[], String[],
                                                  ["extension-module"], true)
        if Sys.iswindows()
            @test plan.mode === :link_libpython
        else
            @test plan.mode === :unlinkable
            @test_throws RustCall.RustError RustCall.pyo3_link_rustflags(plan)
        end
    end

    @testset "link flags: no rpath where there is no rpath" begin
        # `-Wl,-rpath` is a GNU/Apple ld option; link.exe rejects it, and
        # Windows resolves a DLL through PATH rather than a recorded path.
        plan = RustCall.PyO3LinkPlan(:link_libpython, String[], @__DIR__, "test")
        flags = RustCall.pyo3_link_rustflags(plan)
        @test flags[1] == "-L"
        @test flags[2] == "native=$(@__DIR__)"
        if Sys.iswindows()
            @test length(flags) == 2
            @test !any(f -> occursin("rpath", f), flags)
        else
            @test any(f -> occursin("-Wl,-rpath,$(@__DIR__)", f), flags)
        end
    end

    @testset "the link options travel in the wrapper's build script (#307 review)" begin
        # An environment `RUSTFLAGS` is ignored whenever
        # `CARGO_ENCODED_RUSTFLAGS` is set, and replaces a crate's `[build]
        # rustflags` when it is not; a `build.rs` reaches exactly this cdylib's
        # link step.
        linked = RustCall.PyO3LinkPlan(:link_libpython, String[], @__DIR__, "test")
        script = RustCall._pyo3_wrapper_build_script(linked)
        @test occursin("fn main()", script)
        @test occursin("cargo:rustc-link-search=native=$(escape_string(@__DIR__))", script)
        if Sys.iswindows()
            @test !occursin("rpath", script)
        else
            @test occursin("cargo:rustc-link-arg=-Wl,-rpath,$(escape_string(@__DIR__))", script)
        end
        # The same options, as `pyo3_link_rustflags` spells them for the key.
        flags = RustCall.pyo3_link_rustflags(linked)
        @test "native=$(@__DIR__)" in flags
        # Nothing for a build that links no libpython.
        @test RustCall._pyo3_wrapper_build_script(
                  RustCall.PyO3LinkPlan(:python_free, String[], "", "test")) == ""
    end

    @testset "the runtime DLL travels with the plan on Windows (#307 review)" begin
        # Windows has no rpath and the wrapper imports `python3xy.dll` by name,
        # a file beside the interpreter rather than in the `libs` directory it
        # linked against; the plan records the DLL the interpreter itself runs
        # and the module opens it before the wrapper. Elsewhere the rpath does
        # this and nothing is recorded.
        @test RustCall.PyO3LinkPlan(:link_libpython, String[], @__DIR__, "test").runtime_libraries ==
              String[]
        carried = RustCall.PyO3LinkPlan(:link_libpython, String[], @__DIR__, "test";
                                        runtime_libraries = ["C:\\py\\python312.dll"])
        @test carried.runtime_libraries == ["C:\\py\\python312.dll"]
        # No interpreter (a `PYO3_CONFIG_FILE` / `PYO3_CROSS_LIB_DIR`
        # configuration consults none): nothing to record.
        @test RustCall._python_runtime_libraries("") == String[]
        # One that cannot be run: nothing, not an error.
        @test RustCall._python_runtime_libraries(joinpath(@__DIR__, "no_such_python")) == String[]
        interpreter = RustCall._python_executable_on_path()
        if !Sys.iswindows()
            @test RustCall._python_runtime_libraries(interpreter) == String[]
        elseif isempty(interpreter)
            @test_skip "a Python interpreter is required"
        else
            libs = RustCall._python_runtime_libraries(interpreter)
            @test length(libs) == 1
            @test isfile(libs[1])
            @test endswith(lowercase(libs[1]), ".dll")
            @test occursin("python", lowercase(basename(libs[1])))
            # ... and the plan that names this interpreter carries it.
            plan = RustCall._pyo3_unresolved_cfg_plan(".", String[], ["a"], ["macros"], true)
            if plan.interpreter == interpreter
                @test plan.runtime_libraries == libs
            end
        end
    end

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
end
