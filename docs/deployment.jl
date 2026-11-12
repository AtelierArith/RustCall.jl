"""Deployment options shared by the build and the deployment regression tests."""
function documentation_deployment(lang)
    lang in ("en", "ja") || throw(ArgumentError("unsupported documentation language: $lang"))
    return (
        # Documenter's GitHub Actions preflight matches this case-sensitively.
        repo = "github.com/AtelierArith/RustCall.jl.git",
        devbranch = "main",
        push_preview = true,
        dirname = lang,
        target = joinpath("build", lang),
    )
end
