# The program number ARGS[1] of `mpi_cases.jl`, in Julia (what `mpi.jl` compares the compiled one with)
include(joinpath(@__DIR__, "mpi_cases.jl"))
CASES[parse(Int, ARGS[1])](String[])
