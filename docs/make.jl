using Documenter
using RustCall

# The supported-type matrix is generated from the contract itself, so the page
# cannot drift from the table generated code consults (#276, #245 item 4).
include("generate_type_matrix.jl")
generate_type_matrix(joinpath(@__DIR__, "src", "type_contract.md"))

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
            "The FFI Type Contract" => "type_contract.md",
            "Struct Mapping" => "struct_mapping.md",
            "Generics" => "generics.md",
            "External Crate Bindings" => "crate_bindings.md",
            "Precompilation" => "precompilation.md",
            "Troubleshooting" => "troubleshooting.md",
        ],
        "Reference" => [
            "Project Guide" => "project_guide.md",
            "API Reference" => "api.md",
            "Project Status" => "status.md",
            "Developer Pitfalls" => "developer_pitfalls.md",
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
