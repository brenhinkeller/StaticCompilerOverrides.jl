# What compiles from packages: the code of Distributions.jl, NaNStatistics.jl and StatsBase.jl, as programs that have to give what Julia gives.
# This is a survey that is kept as tests, so that what works stays working; it takes a while, so it is not part of the tests of the package:
#
#     julia --project=test/packages -e 'using Pkg; Pkg.develop(path = "."); Pkg.instantiate(); include("test/packages/runtests.jl")'
#
# `PACKAGES=Distributions,StatsBase` (or the names of the files) runs only some of them.

include("common.jl")

const ALL = ["distributions", "nanstatistics", "statsbase"]
selected = get(ENV, "PACKAGES", "")
selected = isempty(selected) ? ALL : [lowercase(strip(s)) for s in split(selected, ',')]

@testset "Packages" begin
    for name in ALL
        any(s -> occursin(s, name) || occursin(name, s), selected) || continue
        include("$name.jl")
    end
end
