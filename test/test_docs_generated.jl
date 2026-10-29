# The docs build regenerates `docs/src/type_contract.md` (`docs/make.jl`), so
# whatever is committed there and the generator does not emit is lost on the
# next build. #419's callbacks section was, twice: from every published build,
# then from the repository when #534 committed a rebuilt copy (#544).
using Test
using RustCall

const _DOCS_DIR = normpath(joinpath(@__DIR__, "..", "docs"))

include(joinpath(_DOCS_DIR, "generate_type_matrix.jl"))

@testset "generated docs pages hold nothing hand-written (#544)" begin
    @testset "type_contract.md is exactly what the generator writes" begin
        committed = read(joinpath(_DOCS_DIR, "src", "type_contract.md"), String)
        generated = mktempdir() do dir
            read(generate_type_matrix(joinpath(dir, "type_contract.md")), String)
        end
        # Line endings are the checkout's business, not the generator's.
        @test replace(committed, "\r\n" => "\n") == generated
    end

    @testset "the callbacks section is a page of its own" begin
        page = read(joinpath(_DOCS_DIR, "src", "callbacks.md"), String)
        @test startswith(page, "# Callbacks: passing a Julia function to Rust")
        for rule in ("**Synchronous borrow.**", "**Same thread.**",
                     "**A Julia exception never unwinds through Rust.**")
            @test occursin(rule, page)
        end
        @test occursin("\"callbacks.md\"", read(joinpath(_DOCS_DIR, "make.jl"), String))
        @test occursin("(callbacks.md)",
                       read(joinpath(_DOCS_DIR, "src", "integration_guide.md"), String))
    end

    @testset "the callbacks page's example computes what it says" begin
        if !RustCall.check_rustc_available()
            @test_skip "rustc not found, skipping the callbacks page example"
        else
            rust"""
            #[julia]
            pub fn apply(f: extern "C" fn(i64) -> i64, x: i64) -> i64 { f(x) + 1 }

            #[julia]
            pub fn each(n: u32, visit: extern "C" fn(u32, f64)) {
                for i in 0..n { visit(i, i as f64 * 0.5) }
            }
            """
            @test apply(x -> 2x, 20) == 41
            k = 10
            @test apply(x -> x + k, 1) == 12
            seen = Float64[]
            each(4, (i, v) -> push!(seen, v))
            @test seen == [0.0, 0.5, 1.0, 1.5]
        end
    end
end
