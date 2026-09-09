using RustCall, Test
include(joinpath(@__DIR__, "pyo3_wrapper_helpers.jl"))

@testset "Cargo built-ins include inherited package metadata (#303)" begin
    mktempdir() do workspace
        write(joinpath(workspace, "Cargo.toml"), """
            [workspace]
            members = ["member"]
            resolver = "2"
            [workspace.package]
            version = "1.2.3-rc.4+build.5"
            authors = ["First", "Second"]
            description = "inherited description"
            license-file = "LICENSE"
            readme = "README.md"
            rust-version = "1.74"
            """)
        write(joinpath(workspace, "LICENSE"), "test license")
        write(joinpath(workspace, "README.md"), "test readme")
        root = joinpath(workspace, "member")
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "Cargo.toml"), """
            [package]
            name = "builtin_target303"
            edition = "2021"
            version.workspace = true
            authors.workspace = true
            description.workspace = true
            license-file.workspace = true
            readme.workspace = true
            rust-version.workspace = true
            [lib]
            name = "builtin_api303"
            [dependencies]
            pyo3 = { version = "0.29", default-features = false, features = ["macros"] }
            """)
        write(joinpath(root, "build.rs"), raw"""
            fn main() {
                let file = std::path::Path::new(&std::env::var("OUT_DIR").unwrap())
                    .join(format!("{}.rs", std::env::var("CARGO_PKG_VERSION").unwrap()));
                std::fs::write(file, r#"
                    #[pyo3::pyfunction] pub fn metadata_values() -> String {
                        concat!(env!("CARGO_PKG_VERSION"), "|", env!("CARGO_PKG_AUTHORS"),
                            "|", env!("CARGO_PKG_DESCRIPTION"), "|", env!("CARGO_PKG_LICENSE_FILE"),
                            "|", env!("CARGO_PKG_README"), "|", env!("CARGO_CRATE_NAME")).to_string()
                    }
                "#).unwrap();
            }
            """)
        write(joinpath(root, "src", "lib.rs"),
            raw"""include!(concat!(env!("OUT_DIR"), "/", env!("CARGO_PKG_VERSION"), ".rs"));""")
        plan = RustCall.pyo3_link_plan(root)
        @test RustCall.scan_crate(root).version == "1.2.3-rc.4+build.5"
        @test plan.resolved
        environment = plan.build_env
        @test environment["CARGO_PKG_VERSION_MAJOR"] == "1"
        @test environment["CARGO_PKG_VERSION_MINOR"] == "2"
        @test environment["CARGO_PKG_VERSION_PATCH"] == "3"
        @test environment["CARGO_PKG_VERSION_PRE"] == "rc.4"
        @test environment["CARGO_PKG_AUTHORS"] == "First:Second"
        @test environment["CARGO_PKG_NAME"] == "builtin_target303"
        @test environment["CARGO_PKG_RUST_VERSION"] == "1.74"
        @test environment["CARGO_PKG_LICENSE"] == ""
        @test environment["CARGO_PKG_HOMEPAGE"] == ""
        @test environment["CARGO_CRATE_NAME"] == "builtin_api303"
        @test isfile(environment["CARGO"])
        wrapper = _link_libpython_wrapper(root)
        if wrapper === nothing
            @test_skip "no linkable Python here"
        else
            binding = @rust_crate root
            module_ = binding.module_ref
            name = Base.invokelatest(getfield, module_, :_LIB_NAME)
            try
                expected = join((environment[key] for key in (
                    "CARGO_PKG_VERSION", "CARGO_PKG_AUTHORS", "CARGO_PKG_DESCRIPTION",
                    "CARGO_PKG_LICENSE_FILE", "CARGO_PKG_README", "CARGO_CRATE_NAME")), "|")
                @test Base.invokelatest(getfield(module_, :metadata_values)) == expected
            finally
                RustCall.unload_library(name; close = true)
                RustCall.close_retired_handles!(RustCall.retired_handles(name))
            end
        end
    end
end

@testset "fresh crate build context does not require an existing lockfile (#303)" begin
    mktempdir() do root
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "Cargo.toml"), """
            [package]
            name = "fresh_context303"
            version = "0.1.0"
            edition = "2021"
            [features]
            extra = []
            """)
        write(joinpath(root, "src", "lib.rs"), """
            #[julia] pub fn base() -> i32 { 1 }
            #[cfg(feature = "extra")]
            #[julia] pub fn extra() -> i32 { 2 }
            """)
        @test !isfile(joinpath(root, "Cargo.lock"))
        context = RustCall._wrapper_probe_context(root)
        @test !isempty(context.cfg_text)
        @test context.build_env !== nothing
        scanned = RustCall.scan_crate(root; cfg = :cargo, cfg_text = context.cfg_text,
                                      build_env = context.build_env)
        @test [f.name for f in scanned.julia_functions] == ["base"]
        enabled = RustCall._wrapper_probe_context(root; features = ["extra"])
        scanned_enabled = RustCall.scan_crate(root; cfg = :cargo, cfg_text = enabled.cfg_text,
                                              build_env = enabled.build_env)
        @test Set(f.name for f in scanned_enabled.julia_functions) == Set(["base", "extra"])
    end
end

@testset "generated-only PyO3 API builds and calls through @rust_crate (#303)" begin
    mktempdir() do parent
        root = joinpath(parent, "crate")
        input = joinpath(parent, "value.txt")
        write(input, "42")
        mkpath(joinpath(root, "src"))
        write(joinpath(root, "Cargo.toml"), """
            [package]
            name = "generated_only303"
            version = "0.1.0"
            edition = "2021"
            build = "generate.rs"
            [dependencies]
            pyo3 = { version = "0.29", default-features = false, features = ["macros"] }
            """)
        write(joinpath(root, "generate.rs"), raw"""
            use std::hash::{Hash, Hasher};
            fn main() {
                let output = std::env::var("OUT_DIR").unwrap();
                let input = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap())
                    .parent().unwrap().join("value.txt");
                let value = std::fs::read_to_string(&input).unwrap().trim().parse::<i32>().unwrap();
                let mut hash = std::collections::hash_map::DefaultHasher::new();
                output.hash(&mut hash);
                std::fs::write(std::path::Path::new(&output).join("api.rs"),
                    format!("#[pyo3::pyfunction] pub fn generated_answer() -> i32 {{ {value} }}\n\
                             #[pyo3::pyfunction] pub fn generated_{}() -> i32 {{ {value} }}\n",
                             hash.finish())).unwrap();
                println!("cargo:rerun-if-changed=generate.rs");
                println!("cargo:rerun-if-changed={}", input.display());
            }
            """)
        write(joinpath(root, "src", "lib.rs"), raw"""include!(concat!(env!("OUT_DIR"), "/api.rs"));""")
        @test isempty(RustCall.scan_crate(root).pyo3_functions)
        @test RustCall.crate_needs_pyo3_wrapper(RustCall.scan_crate(root))
        wrapper = _link_libpython_wrapper(root)
        if wrapper === nothing
            @test_skip "no linkable Python here"
        else
            @test any(path -> Base.Filesystem.samefile(path, input), wrapper.plan.build_inputs)
            modules = Module[]
            binding = @rust_crate root
            module_ = binding.module_ref
            push!(modules, module_)
            try
                @test any(path -> Base.Filesystem.samefile(path, input),
                          getfield(module_, :_CRATE_INPUTS))
                @test Base.invokelatest(getfield(module_, :generated_answer)) == 42
                path_name = Symbol(only(f.name for f in wrapper.info.julia_functions if f.name != "generated_answer"))
                @test Base.invokelatest(getfield(module_, path_name)) == 42
                # The changed input is OUTSIDE the crate. Only the actual
                # generated-source identity can invalidate this cache entry.
                write(input, "43")
                updated_binding = @rust_crate root
                updated = updated_binding.module_ref
                push!(modules, updated)
                @test Base.invokelatest(getfield(updated, :generated_answer)) == 43
                @test getfield(module_, :_LIB_NAME) != getfield(updated, :_LIB_NAME)
                @test Base.invokelatest(getfield(module_, :generated_answer)) == 42
                warm_binding = @rust_crate root
                warm = warm_binding.module_ref
                push!(modules, warm)
                @test getfield(warm, :_LIB_NAME) == getfield(updated, :_LIB_NAME)
                @test Base.invokelatest(getfield(warm, :generated_answer)) == 43
                file = joinpath(parent, "GeneratedBindings.jl")
                RustCall.write_bindings_to_file(root, file; output_module_name = "GeneratedFile303")
                holder = Module(gensym(:GeneratedFileHolder303))
                Base.include(holder, file)
                written = getfield(holder, :GeneratedFile303)
                push!(modules, written)
                @test Base.invokelatest(getfield(written, :generated_answer)) == 43
            finally
                for name in unique(getfield.(modules, :_LIB_NAME))
                    RustCall.unload_library(name; close = true)
                    RustCall.close_retired_handles!(RustCall.retired_handles(name))
                end
            end
        end
    end
end

@testset "build scripts trigger resolved API discovery (#303)" begin
    mktempdir() do root
        write(joinpath(root, "Cargo.toml"), "[package]\nname = \"generated303\"\nversion = \"0.1.0\"\n")
        @test !RustCall._crate_has_build_script(root)
        write(joinpath(root, "build.rs"), "fn main() {}")
        @test RustCall._crate_has_build_script(root)
        write(joinpath(root, "Cargo.toml"), "[package]\nname = \"generated303\"\nbuild = false\n")
        @test !RustCall._crate_has_build_script(root)
        write(joinpath(root, "Cargo.toml"), "[package]\nname = \"generated303\"\nbuild = \"custom/generate.rs\"\n")
        @test RustCall._crate_has_build_script(root)
    end
end

@testset "Cargo build context selects the target package only (#303)" begin
    mktempdir() do root
        target_out = joinpath(root, "target", "release", "build", "target-hash", "out")
        dependency_out = joinpath(root, "target", "release", "build", "dependency-hash", "out")
        mkpath(target_out)
        mkpath(dependency_out)
        write(joinpath(dirname(target_out), "output"),
              "cargo:rerun-if-changed=relative.txt\n" *
              "cargo::rerun-if-changed=$(joinpath(root, "external.txt"))\n")
        write(joinpath(dirname(dependency_out), "output"),
              "cargo:rerun-if-changed=dependency-only.txt\n")
        output = """
        {"reason":"build-script-executed","package_id":"dependency","out_dir":$(repr(dependency_out)),"env":[["API_FILE","wrong.rs"]]}
        {"reason":"build-script-executed","package_id":"target","out_dir":$(repr(target_out)),"env":[["API_FILE","correct.rs"]]}
        unix
        feature="python"
        """
        context = RustCall._cargo_probe_context(output, "target", root)
        @test context.cfg_text == "unix\nfeature=\"python\"\n"
        @test context.build_env["OUT_DIR"] == target_out
        @test context.build_env["API_FILE"] == "correct.rs"
        @test context.build_env["CARGO_MANIFEST_DIR"] == root
        @test context.build_inputs == sort([joinpath(root, "relative.txt"),
                                            joinpath(root, "external.txt")])
        absent = RustCall._cargo_probe_context(output, "absent", root)
        @test !haskey(absent.build_env, "OUT_DIR")
        @test isempty(absent.build_inputs)
    end
end

@testset "generated scan identity is location independent (#303)" begin
    mktempdir() do parent
        identities = Vector{Pair{String, String}}[]
        build_identities = Vector{Pair{String, String}}[]
        for (checkout, build_hash) in (("first", "crate-first-hash"),
                                       ("second", "crate-second-hash"))
            root = joinpath(parent, checkout)
            generated = joinpath(root, "target", "release", "build", build_hash, "out")
            mkpath(joinpath(root, "src"))
            mkpath(generated)
            source = joinpath(root, "src", "lib.rs")
            output = joinpath(generated, "api.rs")
            write(source, "include!(concat!(env!(\"OUT_DIR\"), \"/api.rs\"));")
            write(output, "pub fn answer() -> i32 { 42 }")
            push!(identities, RustCall.artifact_scan_inputs([source, output];
                                                            crate_root = root,
                                                            generated_root = generated))
            plan = RustCall.PyO3LinkPlan(:python_free, String[], "", "test";
                build_env = Dict("CARGO_MANIFEST_DIR" => root,
                                 "CARGO_MANIFEST_PATH" => joinpath(root, "Cargo.toml"),
                                 "OUT_DIR" => generated))
            push!(build_identities, RustCall._pyo3_wrapper_build_env(plan, String[];
                source_files = [source, output], crate_root = root))
        end
        @test identities[1] == identities[2]
        @test build_identities[1] == build_identities[2]
        second_generated = joinpath(parent, "second", "target", "release", "build",
                                    "crate-second-hash", "out")
        write(joinpath(second_generated, "api.rs"),
              "pub fn answer() -> i32 { 43 }")
        changed = RustCall.artifact_scan_inputs(
            [joinpath(parent, "second", "src", "lib.rs"),
             joinpath(second_generated, "api.rs")];
            crate_root = joinpath(parent, "second"),
            generated_root = second_generated)
        @test changed != identities[1]
    end
end

@testset "generated include context crosses the Julia/extractor boundary (#303)" begin
    mktempdir() do root
        generated = joinpath(root, "generated space")
        mkpath(generated)
        source = joinpath(root, "lib.rs")
        write(source, raw"""pub mod api { include!(concat!(env!("OUT_DIR"), "/api.rs")); }""")
        write(joinpath(generated, "api.rs"), "#[pyo3::pyfunction] pub fn generated_answer() -> i32 { 42 }")
        environment = Dict("OUT_DIR" => generated)
        manifest = RustCall.extract_manifest(String[]; mode = "crate", crate_root = source,
                                            cfg = :lenient, build_env = environment)
        @test only(manifest["functions"])["name"] == "generated_answer"
        @test only(manifest["functions"])["module_path"] == ["api"]
        wrapped = RustCall.wrap_crate(String[]; crate_name = "generated_probe303",
                                     crate_root = source, cfg = :lenient, build_env = environment)
        @test occursin("generated_probe303::api::generated_answer", wrapped.lib_rs)
        @test any(path -> Base.Filesystem.samefile(path, joinpath(generated, "api.rs")),
                  wrapped.source_files)
        identity_before = RustCall.artifact_scan_inputs(wrapped.source_files)
        write(joinpath(generated, "api.rs"), "#[pyo3::pyfunction] pub fn generated_answer() -> i32 { 43 }")
        @test RustCall.artifact_scan_inputs(wrapped.source_files) != identity_before
        @test_throws RustCall.ExtractorError RustCall.extract_manifest(String[]; mode = "crate",
            crate_root = source, build_env = Dict{String, String}(), skip_unparsable = true)
    end
end
