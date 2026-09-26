using Test
using RustCall

include("source_helpers.jl")

@testset "Source checks follow component includes" begin
    mktempdir() do dir
        mkpath(joinpath(dir, "nested"))
        write(joinpath(dir, "entry.jl"), """
            include("nested/part.jl")
            quote
                include("generated_file_that_does_not_exist.jl")
            end
            function deferred()
                include("runtime_file_that_does_not_exist.jl")
            end
            """)
        write(joinpath(dir, "nested", "part.jl"), "include(\"leaf.jl\")\n")
        write(joinpath(dir, "nested", "leaf.jl"), "unsafe_operation()\n")
        source = read_source_tree(joinpath(dir, "entry.jl"))
        @test count("unsafe_operation()", source) == 1
        @test read_source_tree(joinpath(dir, "nested", "leaf.jl")) == "unsafe_operation()\n"
        # A missing component fails the check; it cannot silently reduce coverage.
        write(joinpath(dir, "missing.jl"), "include(\"absent.jl\")\n")
        @test_throws SystemError read_source_tree(joinpath(dir, "missing.jl"))
    end

    source = read_source_tree(joinpath(pkgdir(RustCall), "src", "crate_bindings.jl"))
    for definition in ("struct CrateInfo", "struct CrateBuildRecord", "struct ModuleNode",
                       "function emit_crate_module(", "function _generate_crate_function_wrapper(",
                       "function generate_bindings(", "struct CrateBindings",
                       "function write_bindings_to_file(", "function emit_crate_module_code(")
        @test count(definition, source) == 1
    end
end
