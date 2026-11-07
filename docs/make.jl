using StaticCompilerOverrides
using Documenter

DocMeta.setdocmeta!(StaticCompilerOverrides, :DocTestSetup, :(using StaticCompilerOverrides); recursive=true)

makedocs(;
    modules=[StaticCompilerOverrides, StaticCompilerOverrides.Runtime],
    authors="C. Brenhin Keller",
    repo="https://github.com/brenhinkeller/StaticCompilerOverrides.jl/blob/{commit}{path}#{line}",
    sitename="StaticCompilerOverrides.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://brenhinkeller.github.io/StaticCompilerOverrides.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/brenhinkeller/StaticCompilerOverrides.jl",
    devbranch="main",
)
