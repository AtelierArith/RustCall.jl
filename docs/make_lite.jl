using Documenter
using LastCall

makedocs(
    sitename = "LastCall.jl",
    modules = [LastCall],
    pages = [
        "Home" => "index.md",
        "Tutorial" => "tutorial.md",
    ],
)
