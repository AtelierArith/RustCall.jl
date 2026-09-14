using Test
using RustCall

@testset "inline module state restores from immutable precompile records (#251)" begin
    mktempdir() do root
        name = "InlineModuleState251"
        package = joinpath(root, name)
        cache = joinpath(root, "rust-cache")
        mkpath(joinpath(package, "src"))
        write(joinpath(package, "Project.toml"), """
            name = "$name"
            uuid = "6da38dc1-2351-495f-9ad7-701e745bff45"
            version = "0.1.0"
            [deps]
            RustCall = "$(Base.PkgId(RustCall).uuid)"
            """)
        write(joinpath(package, "src", "$name.jl"), join([
            "module $name",
            "using RustCall",
            "rust\"#[julia] pub fn first_value() -> i32 { 11 }\"",
            "rust\"#[julia] pub fn second_value() -> i32 { 22 }\"",
            "total() = first_value() + second_value()",
            "end",
        ], "\n"))
        sep = Sys.iswindows() ? ";" : ":"
        function fresh(script)
            withenv("JULIA_LOAD_PATH" => join((pkgdir(RustCall), root, "@stdlib"), sep),
                    "RUSTCALL_CACHE_DIR" => cache,
                    "RUSTCALL_SUPPRESS_HELPERS_WARNING" => "1") do
                readchomp(`$(Base.julia_cmd()) --startup-file=no -e $script`)
            end
        end
        @test fresh("using $name; print($name.total())") == "33"
        probe = """
            using RustCall
            id = Base.identify_package("$name")
            ready = Base.isprecompiled(id)
            using $name
            was_empty = !haskey(RustCall.MODULE_STATES, $name)
            value = $name.total()
            @assert $name.__RUSTCALL_LIBS isa RustCall.StateView
            @assert $name.__RUSTCALL_LIBS.owner === $name
            print(ready, " ", was_empty, " ", value, " ",
                  length(RustCall._module_block_records($name)), " ",
                  length($name.__RUSTCALL_LIBS))
            """
        @test fresh(probe) == "true true 33 2 2"
        # No library from either previous process survives. Rebuild from the
        # recorded source/config after clearing only this test's Rust cache.
        @test fresh("using RustCall; RustCall.clear_cache(); " * probe) == "true true 33 2 2"
    end
end
