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
        "Rust for Julia Users" => "Julia 利用者のための Rust 入門",
        "Tutorial" => "チュートリアル",
        "What's New in v0.9 and v0.10" => "v0.9 と v0.10 の新機能",
        "Examples" => "使用例", "User Guide" => "利用ガイド",
        "Safe Rust/Julia Integration" => "安全な Rust/Julia 連携",
        "The FFI Type Contract" => "FFI の型契約",
        "Callbacks" => "コールバック", "Struct Mapping" => "構造体の対応付け",
        "Generics" => "ジェネリクス", "External Crate Bindings" => "外部クレートのバインディング",
        "Hot Reload" => "ホットリロード", "PyO3 Crates" => "PyO3 クレート",
        "Panics, Visibility and Lifetime" => "パニック・可視性・生存期間",
        "Precompilation" => "プリコンパイル", "Performance" => "性能",
        "Troubleshooting" => "トラブルシューティング",
        "Migrating from @irust" => "@irust からの移行",
        "Reference" => "リファレンス", "API Reference" => "API リファレンス",
        "Overview" => "概要", "Artifact identity and caching" => "成果物の識別とキャッシュ",
        "The FFI type contract" => "FFI の型契約", "Front doors" => "利用者向けの入口",
        "Compiler and codegen" => "コンパイラとコード生成", "The FFI manifest" => "FFI マニフェスト",
        "Cargo projects and dependencies" => "Cargo プロジェクトと依存関係",
        "External crates" => "外部クレート", "Hot reload API" => "ホットリロード API",
        "PyO3 crates" => "PyO3 クレート", "Types, memory and ownership" => "型・メモリ・所有権",
        "Generics and #[julia] functions" => "ジェネリクスと #[julia] 関数",
        "Errors" => "エラー", "Load policy" => "読み込みポリシー",
        "Project Status" => "プロジェクトの状況", "Developer" => "開発者向け",
        "How RustCall Calls Rust" => "RustCall が Rust を呼ぶ仕組み",
        "Project Guide" => "プロジェクトガイド", "Windows Development" => "Windows での開発",
        "Developer Pitfalls" => "開発時の注意点", "Platforms" => "プラットフォーム",
        "Windows" => "Windows",
    )
    return [get(labels, first(page), first(page)) =>
            (last(page) isa AbstractVector ? japanese_navigation(last(page)) : last(page))
            for page in pages]
end

"""Refuse a docs build when a Japanese counterpart is missing."""
function check_translation_coverage(src)
    missing = String[]
    for (dir, _, files) in walkdir(joinpath(src, "en"))
        for file in files
            endswith(file, ".md") || continue
            relative = relpath(joinpath(dir, file), joinpath(src, "en"))
            isfile(joinpath(src, "ja", relative)) || push!(missing, relative)
        end
    end
    isempty(missing) || error("missing Japanese documentation: " * join(sort!(missing), ", "))
    return nothing
end
