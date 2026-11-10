# What compiles from the standard libraries and from the packages that programs use: a survey that is kept as tests, so that what works stays working. The programs compile to
# executables and have to print what Julia gives for the same code. It takes a few minutes (`GROUP=Packages`, or `GROUP=Core` for the tests of the package alone).
#
# `PACKAGES=Dates,StatsBase` (the names of the files, or parts of them) runs only some of them.
@info "Package tests, including stdlibs:"

@isdefined(check_cases) || include(joinpath(@__DIR__, "..", "helpers.jl"))
include_timed("common.jl")

const STDLIBS = ["linearalgebra", "sparsearrays", "statistics", "dates", "printf", "logging", "encoding", "sha", "uuids", "sockets", "mmap"]
const PACKAGES_TESTED = ["distributions", "nanstatistics", "statsbase", "datastructures", "orderedcollections", "staticarrays", "graphs", "parsers", "mpi"]
const ALL = [STDLIBS; PACKAGES_TESTED]
selected = get(ENV, "PACKAGES", "")
selected = isempty(selected) ? ALL : [lowercase(strip(s)) for s in split(selected, ',')]

for name in ALL
    any(s -> occursin(s, name) || occursin(name, s), selected) || continue
    include_timed("$name.jl")
end
