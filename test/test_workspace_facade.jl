using Test, RustCall

@testset "Several upstream crates, one facade (#624)" begin
    mktempdir() do ws
        runtime = RustCall.escape_toml_string(RustCall.rustcall_runtime_crate_path())
        write(joinpath(ws, "Cargo.toml"), """
        [workspace]
        members = ["shared", "special", "krylov", "facade"]
        resolver = "2"
        """)
        for name in ("shared", "special", "krylov", "facade")
            mkpath(joinpath(ws, name, "src"))
            extra = name == "shared" ? "" : name == "facade" ? """
        [lib]
        crate-type = ["cdylib"]
        [dependencies]
        special = { path = "../special" }
        krylov = { path = "../krylov" }
        rustcall_julia_macros = { path = "$runtime" }
        """ : """
        [dependencies]
        shared = { path = "../shared" }
        """
            write(joinpath(ws, name, "Cargo.toml"), """
        [package]
        name = "$name"
        version = "0.1.0"
        edition = "2021"
        """ * extra)
        end
        write(joinpath(ws, "shared", "src", "lib.rs"),
              "pub fn bump(x: i32) -> i32 { x + 1 }
        ")
        for name in ("special", "krylov")
            write(joinpath(ws, name, "src", "lib.rs"),
                  "pub fn run(x: i32) -> i32 { shared::bump(x) }
        ")
        end
        write(joinpath(ws, "facade", "src", "lib.rs"), raw"""
        use rustcall_julia_macros::julia;
        #[julia]
        pub mod special {
            use rustcall_julia_macros::julia;
            #[julia]
            pub fn run(x: i32) -> i32 { ::special::run(x) }
        }
        #[julia]
        pub mod krylov {
            use rustcall_julia_macros::julia;
            #[julia]
            pub fn run(x: i32) -> i32 { ::krylov::run(x) }
        }
        """)
        facade = joinpath(ws, "facade")
        cargo_manifest = joinpath(facade, "Cargo.toml")
        target = joinpath(ws, "artifact-probe")
        cmd = `$(RustCall.cargo()) build --release --manifest-path $cargo_manifest --target-dir $target --message-format=json`
        function shared_artifact()
            events = RustCall.parse_json.(readlines(cmd))
            return only(event for event in events if
                event["reason"] == "compiler-artifact" && event["target"]["name"] == "shared")
        end
        first_build = shared_artifact()
        @test !first_build["fresh"]
        second_build = shared_artifact()
        @test second_build["fresh"]
        @test second_build["filenames"] == first_build["filenames"]

        bindings = Core.eval(@__MODULE__, :(@rust_crate $facade))
        lib = Base.invokelatest(getfield, getfield(bindings, :module_ref), :_LIB_NAME)
        try
            @test Base.invokelatest(() -> bindings.special.run(Int32(2))) === Int32(3)
            @test Base.invokelatest(() -> bindings.krylov.run(Int32(7))) === Int32(8)

            output = joinpath(ws, "bindings.jl")
            RustCall.write_bindings_to_file(facade, output; output_module_name = "WorkspaceFacade624")
            content = read(output, String)
            @test occursin("rustcall_special__run", content)
            @test occursin("rustcall_krylov__run", content)
            host = Module(:WorkspaceFacade624Host)
            Base.include(host, output)
            written = Base.invokelatest(getfield, host, :WorkspaceFacade624)
            written_lib = Base.invokelatest(getfield, written, :_LIB_NAME)
            try
                @test Base.invokelatest(() -> written.special.run(Int32(2))) === Int32(3)
                @test Base.invokelatest(() -> written.krylov.run(Int32(7))) === Int32(8)
            finally
                RustCall.unload_library(written_lib; close = true)
            end
        finally
            RustCall.unload_library(lib; close = true)
        end
        write(joinpath(ws, "shared", "src", "lib.rs"),
              "pub fn bump(x: i32) -> i32 { x + 2 }\n")
        updated = Core.eval(@__MODULE__, :(@rust_crate $facade))
        updated_lib = Base.invokelatest(getfield, getfield(updated, :module_ref), :_LIB_NAME)
        try
            @test Base.invokelatest(() -> updated.special.run(Int32(2))) === Int32(4)
            @test Base.invokelatest(() -> updated.krylov.run(Int32(7))) === Int32(9)
        finally
            RustCall.unload_library(updated_lib; close = true)
        end
    end
end
