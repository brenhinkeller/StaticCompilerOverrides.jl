# MPI.jl: programs that are compiled and run on 3 processes with `mpiexec`, and compared (what each process writes) with the same program run by Julia the same way.
# The library is the one that MPI.jl uses (MPICH_jll by default): the program opens it, at the path that it has when compiling. Not supported, and listed as broken:
# a reduction with an operator that is a function of the user's (`MPI.Allreduce(x, f, comm)`, which makes a C function that calls Julia), and `MPI.send` / `MPI.recv` of
# any object (they use `Serialization`).
using MPI

include("mpi_cases.jl")

function mpi_lines(cmd)
    out = try
        read(pipeline(ignorestatus(cmd), stderr = devnull), String)
    catch err
        "ERROR " * string(err)
    end
    return sort(filter(!isempty, split(out, '\n')))
end

# (`MPI.Op` of a function makes a C function from a closure, which Julia does not do on ARM, where MPI.jl raises an error: there it can't be compared)
const MPI_BROKEN = Sys.ARCH === :x86_64 ? (:c_objects,) : (:c_customop, :c_objects)

@testset "MPI.jl" begin
    dir = mktempdir()
    @testset "$(nameof(f))" for (i, f) in enumerate(CASES)
        name = string(nameof(f))
        if nameof(f) in MPI_BROKEN
            @test_broken (compile_executable(f, (Vector{String},), dir, name); true)
            continue
        end
        exe = compile_executable(f, (Vector{String},), dir, name)
        compiled = mpi_lines(`$(MPI.mpiexec()) -n 3 $exe`)
        expected = mpi_lines(`$(MPI.mpiexec()) -n 3 $(Base.julia_cmd()) --project=$(Base.active_project()) $(joinpath(@__DIR__, "mpi_run.jl")) $i`)
        @test !isempty(expected)
        @test compiled == expected
    end
end
