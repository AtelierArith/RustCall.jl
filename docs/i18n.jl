"""Copy English pages and overlay available translations, marking fallbacks."""
function stage_language(src, dest, lang)
    lang in ("en", "ja") || error("unsupported documentation language: $lang")
    cp(joinpath(src, "en"), dest)
    for (dir, _, files) in walkdir(dest)
        for file in files
            endswith(file, ".md") || continue
            path = joinpath(dir, file)
            relative = relpath(path, dest)
            translated = joinpath(src, lang, relative)
            fallback = lang != "en" && !isfile(translated)
            content = read(isfile(translated) ? translated : path, String)
            notice = fallback ? "!!! note \"未翻訳：英語原文\"\n    このページはまだ翻訳されていません。以下に同じバージョンの英語原文を掲載しています。\n\n" : ""
            # A browser-relative link preserves version, preview, page and URL style.
            switcher = """
            ```@raw html
            <nav aria-label="Language"><a class="language-en" lang="en">English</a> / <a class="language-ja" lang="ja">日本語</a></nav>
            <script>
            for (const lang of ['en', 'ja']) {
                const url = new URL(location.href);
                url.pathname = url.pathname.replace(/\\/(en|ja)\\//, '/' + lang + '/');
                url.hash = '';
                document.querySelector('.language-' + lang).href = url.href;
            }
            </script>
            ```

            """
            write(path, switcher * notice * content)
        end
    end
    return dest
end

function japanese_navigation(pages)
    labels = Dict(
        "Home" => "ホーム", "Getting Started" => "はじめに",
        "Tutorial" => "チュートリアル", "User Guide" => "利用ガイド",
        "Reference" => "リファレンス", "API Reference" => "API リファレンス",
        "Developer" => "開発者向け", "Platforms" => "プラットフォーム",
        "Troubleshooting" => "トラブルシューティング",
    )
    return [get(labels, first(page), first(page)) =>
            (last(page) isa AbstractVector ? japanese_navigation(last(page)) : last(page))
            for page in pages]
end
