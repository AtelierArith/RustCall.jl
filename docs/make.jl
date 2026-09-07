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
        # The API reference is one page per group of source files
        # (`docs/src/reference/`, #288), each with its own `@autodocs`
        # `Pages` filter, so no single page renders every docstring in the
        # package and the hard limit is Documenter's default again (the
        # largest page renders at about 125 KiB). If a reference page grows
        # past the warning, split it further rather than raising the limit:
        # the single-page reference hit the limit twice (500 KiB, then #287
        # at 501.2 KiB).
        size_threshold = 200 * 2^10,         # 200 KiB — hard failure (Documenter's default)
        size_threshold_warn = 150 * 2^10,    # 150 KiB — warn, split before it fails
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
            "PyO3 Crates" => "pyo3.md",
            "Panics, Visibility and Lifetime" => "panics.md",
            "Precompilation" => "precompilation.md",
            "Troubleshooting" => "troubleshooting.md",
        ],
        "Reference" => [
            "Project Guide" => "project_guide.md",
            "API Reference" => [
                "Overview" => "api.md",
                "Artifact identity and caching" => "reference/artifacts.md",
                "The FFI type contract" => "reference/ffi_contract.md",
                "Compilation and codegen" => "reference/compilation.md",
                "The FFI manifest" => "reference/manifest.md",
                "Cargo projects and dependencies" => "reference/cargo.md",
                "External crates and hot reload" => "reference/crates.md",
                "PyO3 crates" => "reference/pyo3.md",
                "Types, memory and ownership" => "reference/ownership.md",
                "Generics and #[julia] functions" => "reference/generics.md",
                "Errors and load policy" => "reference/loading.md",
                "LLVM integration (deprecated)" => "reference/llvm.md",
            ],
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
