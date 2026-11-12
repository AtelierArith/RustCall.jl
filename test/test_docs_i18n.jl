using Test

include(joinpath(@__DIR__, "..", "docs", "i18n.jl"))

@testset "documentation language staging" begin
    mktempdir() do root
        src = joinpath(root, "src")
        mkpath(joinpath(src, "en", "reference"))
        mkpath(joinpath(src, "ja"))
        write(joinpath(src, "en", "index.md"), "# English home\n")
        write(joinpath(src, "ja", "index.md"), "# 日本語\n")
        write(joinpath(src, "en", "reference", "api.md"), "# API\n```@autodocs\nModules = [RustCall]\n```\n")
        for lang in ("en", "ja")
            dest = stage_language(src, joinpath(root, lang), lang)
            home = read(joinpath(dest, "index.md"), String)
            api = read(joinpath(dest, "reference", "api.md"), String)
            @test occursin(lang == "ja" ? "# 日本語" : "# English home", home)
            @test !occursin("未翻訳：英語原文", home)
            @test occursin("未翻訳：英語原文", api) == (lang == "ja")
            @test occursin("```@autodocs", api)
            @test occursin("language-en", home)
            @test occursin("language-ja", api)
        end
        @test read(joinpath(src, "en", "index.md"), String) == "# English home\n"
        @test_throws ErrorException stage_language(src, joinpath(root, "fr"), "fr")
    end
    @test japanese_navigation(["Home" => "index.md", "Reference" => ["Other" => "api.md"]]) ==
          ["ホーム" => "index.md", "リファレンス" => ["Other" => "api.md"]]
end
