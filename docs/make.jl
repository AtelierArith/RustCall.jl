using Documenter
using LastCall

makedocs(
    sitename = "LastCall.jl",
    modules = [LastCall],
    authors = "Satoshi Terasaki",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://atelierarith.github.io/LastCall.jl",
        assets = String[],
    ),
    pages = [
        "Home" => "index.md",
        "Getting Started" => [
            "Tutorial" => "tutorial.md",
            "Examples" => "examples.md",
        ],
        "User Guide" => [
            "Generics" => "generics.md",
            "Troubleshooting" => "troubleshooting.md",
        ],
        "Reference" => [
            "API Reference" => "api.md",
            "Project Status" => "status.md",
        ],
        "Design" => [
            "Phase 1" => "design/Phase1.md",
            "Phase 2" => "design/Phase2.md",
            "Internal" => "design/INTERNAL.md",
            "LLVM Call" => "design/LLVMCALL.md",
        ],
    ],
    warnonly = [:missing_docs, :cross_references],
)

deploydocs(
    repo = "github.com/atelierarith/LastCall.jl.git",
    devbranch = "main",
    push_preview = true,
)
