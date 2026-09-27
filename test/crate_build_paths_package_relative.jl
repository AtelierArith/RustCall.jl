# Keep the package-layout example in @rust_crate working from a real
# package's `src/` directory, where @__DIR__ is evaluated at the call site.

using Test
using RustCall
using RustToolChain: cargo

function _package_relative_cargo_available()
    try
        run(pipeline(`$(cargo()) --version`, devnull))
        return true
    catch
        return false
    end
end

function _package_relative_crate!(path::AbstractString)
    mkpath(joinpath(path, "src"))
    runtime = RustCall.rustcall_runtime_crate_path()
    write(joinpath(path, "Cargo.toml"), """
        [package]
        name = "cbp-package-path-534"
        version = "0.1.0"
        edition = "2021"

        [lib]
        crate-type = ["cdylib"]

        [dependencies]
        rustcall_julia_macros = { path = "$(RustCall.escape_toml_string(runtime))" }
        """)
    write(joinpath(path, "src", "lib.rs"), """
        use rustcall_julia_macros::julia;

        #[julia]
        pub fn package_relative_path() -> i32 { 534 }
        """)
    return String(path)
end

@testset "the package-relative @rust_crate example stays under the package" begin
    if !RustCall.check_rustc_available() || !_package_relative_cargo_available()
        @test_skip "rustc and cargo are required"
    else
        mktempdir() do root
            package_root = joinpath(root, "MyPkg")
            source_dir = joinpath(package_root, "src")
            _package_relative_crate!(joinpath(package_root, "deps", "my_crate"))
            mkpath(source_dir)
            entrypoint = joinpath(source_dir, "bindings.jl")
            write(entrypoint, """
                module CbpPackageRelativePath
                using RustCall
                @rust_crate joinpath(@__DIR__, "..", "deps", "my_crate") submodule="Bindings"
                using .Bindings: package_relative_path
                end
                """)

            include_module = Module(gensym(:PackagePathInclude))
            Base.include(include_module, entrypoint)
            package_module = getfield(include_module, :CbpPackageRelativePath)
            package_relative_path = Base.invokelatest(
                getproperty, package_module, :package_relative_path)
            @test Base.invokelatest(package_relative_path) === Int32(534)
        end
    end
end
