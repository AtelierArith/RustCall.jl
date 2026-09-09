using RustCall, Test
include(joinpath(@__DIR__, "pyo3_wrapper_helpers.jl"))

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
            modules = Module[]
            binding = @rust_crate root
            module_ = binding.module_ref
            push!(modules, module_)
            try
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
    output = """
    {"reason":"build-script-executed","package_id":"dependency","out_dir":"/wrong","env":[["API_FILE","wrong.rs"]]}
    {"reason":"build-script-executed","package_id":"target","out_dir":"/correct","env":[["API_FILE","correct.rs"]]}
    unix
    feature="python"
    {"reason":"build-script-executed","package_id":"other","out_dir":"/also-wrong","env":[]}
    """
    context = RustCall._cargo_probe_context(output, "target", "/crate")
    @test context.cfg_text == "unix\nfeature=\"python\"\n"
    @test context.build_env["OUT_DIR"] == "/correct"
    @test context.build_env["API_FILE"] == "correct.rs"
    @test context.build_env["CARGO_MANIFEST_DIR"] == "/crate"
    @test !haskey(RustCall._cargo_probe_context(output, "absent", "/crate").build_env, "OUT_DIR")
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
        @test realpath(joinpath(generated, "api.rs")) in wrapped.source_files
        identity_before = RustCall.artifact_scan_inputs(wrapped.source_files)
        write(joinpath(generated, "api.rs"), "#[pyo3::pyfunction] pub fn generated_answer() -> i32 { 43 }")
        @test RustCall.artifact_scan_inputs(wrapped.source_files) != identity_before
        @test_throws RustCall.ExtractorError RustCall.extract_manifest(String[]; mode = "crate",
            crate_root = source, build_env = Dict{String, String}(), skip_unparsable = true)
    end
end
