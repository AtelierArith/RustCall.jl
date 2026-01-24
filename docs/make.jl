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
        edit_link = :commit,
        size_threshold = 512000,  # Increase threshold for large API documentation (500 KiB in bytes)
    ),
    warnonly = [:missing_docs],
    pages = [
        "Home" => "index.md",
        "Getting Started" => [
            "Tutorial" => "tutorial.md",
            "Examples" => "examples.md",
        ],
        "User Guide" => [
            "Struct Mapping" => "struct_mapping.md",
            "Generics" => "generics.md",
            "External Crate Bindings" => "crate_bindings.md",
            "Precompilation" => "precompilation.md",
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
)

deploydocs(
    repo = "github.com/atelierarith/LastCall.jl.git",
    devbranch = "main",
    push_preview = true,
)
