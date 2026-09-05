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
        # `api.md` is a single generated page that renders every docstring in
        # the package, so its size is a function of how well documented
        # RustCall is — and Documenter's limit has already been hit twice by
        # ordinary docstring additions (the previous bump to 500 KiB, then
        # #287 at 501.2 KiB). A limit that turns "wrote a docstring" into a red
        # Documentation job pushes in exactly the wrong direction, so give it
        # real margin instead of tracking the page upwards a kilobyte at a time.
        #
        # This is a stopgap. The proper fix is to split the reference into
        # per-module pages with their own `@autodocs` `Pages` filters, after
        # which the threshold can go back near Documenter's default: #288.
        size_threshold = 1_000 * 2^10,       # 1000 KiB — hard failure
        size_threshold_warn = 750 * 2^10,    # 750 KiB — warn, act before it fails
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
