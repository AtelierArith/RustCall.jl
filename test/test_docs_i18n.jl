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
        @test_throws ErrorException check_translation_coverage(src)
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
        mkpath(joinpath(src, "ja", "reference"))
        write(joinpath(src, "ja", "reference", "api.md"), "# API リファレンス\n")
        @test check_translation_coverage(src) === nothing
        @test_throws ErrorException stage_language(src, joinpath(root, "fr"), "fr")
    end
    @test japanese_navigation(["Home" => "index.md", "Reference" => ["Other" => "api.md"]]) ==
          ["ホーム" => "index.md", "リファレンス" => ["Other" => "api.md"]]
end

@testset "complete Japanese documentation" begin
    docs_src = joinpath(@__DIR__, "..", "docs", "src")
    @test check_translation_coverage(docs_src) === nothing
    for (page, id) in ("index.md" => "home", "tutorial.md" => "tutorial",
                       "troubleshooting.md" => "troubleshooting")
        @test occursin("(@id $id)", read(joinpath(docs_src, "ja", page), String))
    end
    include(joinpath(@__DIR__, "..", "docs", "navigation.jl"))
    function check_navigation(english, japanese)
        @test length(english) == length(japanese)
        for (en, ja) in zip(english, japanese)
            @test first(en) == "Windows" || first(en) != first(ja)
            if last(en) isa AbstractVector
                check_navigation(last(en), last(ja))
            else
                @test last(en) == last(ja)
                text = read(joinpath(docs_src, "ja", last(ja)), String)
                @test occursin("<!-- Translation source:", text)
                @test occursin(r"[ぁ-んァ-ヶ一-龠]", text)
                original = read(joinpath(docs_src, "en", last(en)), String)
                @test text != original
                # Translations must retain runnable examples and Documenter directives.
                fences = r"(?ms)^[ \t]*`{3,}[^\n]*\n.*?^[ \t]*`{3,}[^\n]*(?:\n|$)"
                function code_block(m)
                    content = replace(m.match, "\r\n" => "\n")
                    indent = match(r"^[ \t]*", content).match
                    lines = split(content, '\n')
                    return rstrip(join((startswith(line, indent) ?
                                        chop(line; head = length(indent), tail = 0) : line
                                        for line in lines), '\n'))
                end
                @test [code_block(m) for m in eachmatch(fences, text)] ==
                      [code_block(m) for m in eachmatch(fences, original)]
                prose = replace(text, fences => "")
                headings = collect(eachmatch(r"(?m)^#{1,6} .*$", prose))
                @test length(headings) == count(r"(?m)^#{1,6} ", replace(original, fences => ""))
                @test all(m -> occursin(r"\(@id .+\)$", m.match), headings)
            end
        end
    end
    check_navigation(EN_PAGES, japanese_navigation(EN_PAGES))
end
