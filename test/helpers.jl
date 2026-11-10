# Helpers that the tests share: a program is compiled to an executable, and has to give what Julia gives for the same code.

using Test, Random, Printf, Libdl
using StaticCompilerOverrides

# `include` of a file of the tests that is timed (`TEST_TIMING=1` prints the times at the end of `runtests.jl`)
const FILE_TIMES = Pair{String,Float64}[]
function include_timed(path::AbstractString)
    t0 = time()
    include(path)
    push!(FILE_TIMES, path => time() - t0)
    return nothing
end

const ENTRY_TYPES = (Int, Ptr{Ptr{UInt8}})

"""
    compile_main(f; kwargs...) -> path

Compile the zero-argument `f` as the program that prints its result (see `make_main`), and return the path of the executable.
"""
function compile_main(f; kwargs...)
    main = StaticCompilerOverrides.make_main(f)
    return Base.invokelatest(compile_executable, main, ENTRY_TYPES, mktempdir(), string(nameof(main)); kwargs...)
end

# what the program of `f` writes to its standard output (including the result, in the last line)
compiled_stdout(f; kwargs...) = read(`$(compile_main(f; kwargs...))`, String)

# what the program of `f` writes to its standard error
function stderr_of(f; kwargs...)
    err = IOBuffer()
    run(pipeline(`$(compile_main(f; kwargs...))`; stdout = devnull, stderr = err))
    return String(take!(err))
end

# compile `main(argc, argv)`, run it, and return what it prints
function run_main(main; dir = mktempdir())
    exe = Base.invokelatest(compile_executable, main, ENTRY_TYPES, dir, string(nameof(main)))
    return readchomp(`$exe`)
end

# a value that the compiler does not know the type of
any_value(x) = Base.inferencebarrier(x)

# (libm can differ from Julia's in the last bit: results of functions of it are compared to 6 digits)
r6(x) = round(Int, 1e6 * x)

"""
    check_cases(cases; broken = (), batch = true, chunk = 24, kwargs...)

Each element of `cases` is a testset: the program of a zero-argument function has to compile, and give what the function gives in Julia (what it writes, and its result: see
`static_status`). An element is `name => f`, or a function (named by its name). The names in `broken` are the cases that don't work yet: when one does, it is an unexpected pass
that has to be taken off the list.

The cases have to be independent of each other: they are compiled in groups of `chunk` (`batch = true`), each group as one program that runs them in turn, which is much faster than a
program for each; a group that does not pass is compiled again case by case, so that what is said of a case is what it would be on its own. `kwargs` are the options of the compilation.
"""
function check_cases(cases; broken = (), batch::Bool = true, chunk::Int = 24, kwargs...)
    named = [c isa Pair ? c : string(nameof(c)) => c for c in cases]
    isbroken = [name in broken for (name, _) in named]
    statuses = Vector{Tuple{Symbol,String}}(undef, length(named))
    todo = [i for i in eachindex(named) if !isbroken[i]]
    for group in Iterators.partition(todo, batch ? chunk : 1)
        fs = Function[named[i][2] for i in group]
        statuses[group] = StaticCompilerOverrides.static_status_batch(fs; kwargs...)
    end
    for (i, (name, f)) in enumerate(named)
        @testset "$name" begin
            if isbroken[i]
                @test_broken static_status(f; kwargs...)[1] == :ok
            else
                status, detail = statuses[i]
                @test (status, first(replace(string(detail), '\n' => ' '), 300)) == (:ok, "")
            end
        end
    end
    return nothing
end
