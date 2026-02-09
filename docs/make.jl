using Documenter
using RustCall

makedocs(
    sitename = "RustCall.jl",
    modules = [RustCall],
    authors = "Satoshi Terasaki",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        canonical = "https://atelierarith.github.io/RustCall.jl",
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
            "Developer Pitfalls" => "developer_pitfalls.md",
        ],
        "Design" => [
            "Phase 1" => "design/Phase1.md",
            "Phase 2" => "design/Phase2.md",
            "Internal" => "design/INTERNAL.md",
            "LLVM Call" => "design/LLVMCALL.md",
        ],
        "Platforms" => [
            "Windows" => "platforms/windows.md",
        ],
    ],
)

deploydocs(
    repo = "github.com/AtelierArith/RustCall.jl.git",
    devbranch = "main",
    push_preview = true,
)
