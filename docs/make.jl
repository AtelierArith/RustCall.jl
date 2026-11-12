using Documenter
using RustCall

include("generate_type_matrix.jl")
include("navigation.jl")
include("i18n.jl")

generate_type_matrix(joinpath(@__DIR__, "src", "en", "type_contract.md"))

# Stage fallback pages without adding generated translations to the source tree.
mktempdir() do staging
    for lang in ("en", "ja")
        source = joinpath(staging, lang)
        stage_language(joinpath(@__DIR__, "src"), source, lang)
        makedocs(
            root = @__DIR__,
            source = source,
            build = "build/$(lang)",
            sitename = lang == "ja" ? "RustCall.jl 日本語" : "RustCall.jl",
            modules = [RustCall],
            authors = "Satoshi Terasaki",
            format = Documenter.HTML(
                lang = lang,
                prettyurls = get(ENV, "CI", nothing) == "true",
                canonical = "https://atelierarith.github.io/RustCall.jl/$(lang)/stable/",
                edit_link = nothing, # Staged pages have no repository source path.
                assets = String[],
                size_threshold = 200 * 2^10,
                size_threshold_warn = 150 * 2^10,
            ),
            warnonly = [:missing_docs],
            pages = lang == "ja" ? japanese_navigation(EN_PAGES) : EN_PAGES,
        )
    end
end

# Each language owns its version selector and PR previews. Deploy sequentially.
for lang in ("en", "ja")
    deploydocs(
        repo = "github.com/atelierarith/RustCall.jl.git",
        devbranch = "main",
        push_preview = true,
        dirname = lang,
        target = "build/$(lang)",
    )
end
