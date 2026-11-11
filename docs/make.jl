using StaticRuntime
using Documenter

DocMeta.setdocmeta!(StaticRuntime, :DocTestSetup, :(using StaticRuntime); recursive=true)

makedocs(;
    modules=[StaticRuntime, StaticRuntime.Runtime],
    authors="C. Brenhin Keller",
    repo="https://github.com/brenhinkeller/StaticRuntime.jl/blob/{commit}{path}#{line}",
    sitename="StaticRuntime.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://brenhinkeller.github.io/StaticRuntime.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/brenhinkeller/StaticRuntime.jl",
    devbranch="main",
)
