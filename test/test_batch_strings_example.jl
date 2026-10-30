using Test
using RustCall

if RustCall.check_rustc_available()
    include(joinpath(@__DIR__, "..", "examples", "batch_strings", "BatchStrings.jl"))

    @testset "#555 batch string pairs" begin
        replace_batch = BatchStrings.replace_batch
        @test replace_batch("a+b", ["a" => "b", "b" => "猫"]) == "猫+猫"
        @test replace_batch("é:猫", ["é:" => "🙂:", "猫" => ""]) == "🙂:"
        @test replace_batch("a\0b", ["\0" => ":"]) == "a:b"
        @test replace_batch("unchanged", Pair{String,String}[]) == "unchanged"
        @test_throws ArgumentError replace_batch("abc", ["a" => "b", "" => "x"])
        @test_throws ArgumentError replace_batch("abc", ["a" => String(UInt8[0xff])])
        # A malformed frame is rejected before any replacement, including when
        # a valid pair precedes it. Test truncation, overflow, and UTF-8 splits.
        for frame in ("1:a1:b1:x", "999999999999999999999999999999:x", "1:é0:", "x:a0:")
            result = BatchStrings.batch_replace("abc", frame)
            @test RustCall.is_err(result)
        end
        @test replace_batch("abc", ["a" => "z"]) == "zbc"
    end
else
    @testset "#555 batch string pairs" begin
        @test_skip "rustc is required"
    end
end
