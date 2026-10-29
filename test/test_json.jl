# The minimal JSON reader (`src/build/json.jl`) that reads Cargo's
# machine-readable output (`cargo metadata`, `--message-format=json`). Its
# tests lived with `@irust`'s type probe, its first user, until #538.
using Test
using RustCall

@testset "parse_json" begin
    @test RustCall.parse_json("{\"a\": [1, 2.5, true, null], \"b\": \"x\\ny\"}") ==
          Dict{String, Any}("a" => Any[1, 2.5, true, nothing], "b" => "x\ny")
    @test RustCall.parse_json("\"\\u00e9\\u0041\"") == "éA"
    @test RustCall.parse_json("[]") == Any[]
    @test RustCall.parse_json("{}") == Dict{String, Any}()
    @test RustCall.parse_json("  -12  ") === -12
    @test RustCall.parse_json("1e3") === 1000.0
    # Duplicate keys keep the last value.
    @test RustCall.parse_json("{\"k\": 1, \"k\": 2}") == Dict{String, Any}("k" => 2)
    @test_throws RustCall.JSONParseError RustCall.parse_json("{\"a\": }")
    @test_throws RustCall.JSONParseError RustCall.parse_json("[1, 2")
    @test_throws RustCall.JSONParseError RustCall.parse_json("[1] 2")
end
