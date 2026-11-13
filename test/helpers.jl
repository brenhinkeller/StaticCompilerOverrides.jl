# Helpers that the tests share: a program is compiled to an executable, and has to give what Julia gives for the same code.

using Test, Random, Printf, Libdl
using StaticRuntime

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
    main = StaticRuntime.make_main(f)
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

# A number that is `x`, and that neither Julia nor LLVM can know when compiling (it is added to the top bit of the clock, which is zero until the year 2262). A program whose values are
# constants is run by the compiler, and what is compiled is a print of the answer: so what a case has to run (an exception, an allocation, a loop) has to depend on a number like this.
opaque(x::Integer) = x + oftype(x, time_ns() >> 63)
opaque(x::AbstractFloat) = x + oftype(x, time_ns() >> 63)
# (a value that is chosen when the program runs, between `x` and another: the clock is not at 2262 yet)
opaque(x::Symbol) = time_ns() >> 63 == 0 ? x : :opaque_other
opaque(x::String) = time_ns() >> 63 == 0 ? x : "opaque_other"

# The calls whose arguments stay as they are in `@opaque`: the ones that have to be constants for the types to be known (`Val(3)`, `ntuple(f, 3)`), the fields that are named, and the calls to C
const OPAQUE_KEEP = (:Val, :ntuple, :getfield, :setfield!, :getproperty, :setproperty!, :fieldtype, :hasfield, :NamedTuple, :ccall, :Symbol, :Tuple, :NTuple, :reshape, :zeros, :ones, :fill, :Matrix, :Vector, :Array, :ones, :rand, :randn)

"""
    @opaque expr

`expr` with the literal numbers, strings and symbols made `opaque`: values that are the same when the program runs, and that the compiler does not know. A function of constants is run by
the compiler, and the program is a print of its answer; with this, what the case does (an allocation, a lookup, a loop) is done by the program. The arguments of the calls that need a
constant (`Val`, `ntuple`, the name of a field, the dimensions of an array) and of `@`-macros are left as they are.
"""
macro opaque(ex)
    return esc(opaque_literals(ex))
end
function opaque_literals(ex)
    ex isa Union{Bool, Char} && return ex
    ex isa Number && return :($opaque($ex))
    ex isa String && return :($opaque($ex))
    ex isa QuoteNode && ex.value isa Symbol && return :($opaque($ex))
    ex isa Expr || return ex
    head, args = ex.head, ex.args
    head in (:quote, :macrocall, :curly, :ccall, :where, :local, :global, :import, :using, :meta, :inbounds, :loopinfo, :$) && return ex
    if head === :.  # `x.name` (the name stays), and `f.(args)`
        return args[2] isa QuoteNode ? Expr(:., opaque_literals(args[1]), args[2]) : Expr(:., args[1], opaque_literals(args[2]))
    end
    if head === :(::)
        return length(args) == 2 ? Expr(:(::), opaque_literals(args[1]), args[2]) : ex # (the type stays)
    elseif head === :string
        return Expr(:string, (a isa String ? a : opaque_literals(a) for a in args)...)
    elseif head === :call
        f = args[1]
        name = f isa Symbol ? f : (f isa Expr && f.head === :. && f.args[end] isa QuoteNode ? f.args[end].value : nothing)
        name in OPAQUE_KEEP && return ex
        return Expr(:call, f, (opaque_literals(a) for a in args[2:end])...)
    elseif head === :(->)
        return Expr(:(->), args[1], opaque_literals(args[2]))
    elseif head === :function || (head === :(=) && args[1] isa Expr && args[1].head === :call)
        return Expr(head, args[1], opaque_literals(args[2]))
    end
    return Expr(head, (opaque_literals(a) for a in args)...)
end

# (libm can differ from Julia's in the last bit: results of functions of it are compared to 6 digits)
r6(x) = round(Int, 1e6 * x)

# The number of instructions in the program of the zero-argument `f` (without the runtime, which is added when the program is made): a program that only prints a constant has a few,
# because the compiler has run `f`.
function program_size(f)
    main = StaticRuntime.make_main(f)
    return Base.invokelatest() do
        StaticRuntime.StaticCompiler.GPUCompiler.JuliaContext() do ctx
            # (the objects are embedded in the module, in place of their addresses, as the runtime does it: before that the module has raw pointers, which StaticCompiler warns about. The rest of the runtime is not linked)
            size = Ref(0)
            count_program!(mod) = begin
                e = StaticRuntime.Runtime.ObjectEmbedder(mod, Dict())
                StaticRuntime.Runtime.define_well_known_objects!(e)
                StaticRuntime.Runtime.embed_constants!(e)
                size[] = sum(count(_ -> true, (i for bb in LLVM.blocks(fn) for i in LLVM.instructions(bb))) for fn in LLVM.functions(mod) if !LLVM.isdeclaration(fn) && !startswith(LLVM.name(fn), "j_"); init = 0)
                return mod
            end
            mod = Base.invokelatest(static_llvm_module, main, ENTRY_TYPES; strict = false, llvm_postprocess = count_program!)
            LLVM.dispose(mod)
            size[]
        end
    end
end
const FOLDED_LIMIT = 14 # (a program that prints a constant has about 10)
check_folded() = !isempty(get(ENV, "TEST_FOLDED", ""))

"""
    check_cases(cases; broken = (), folded_ok = (), batch = true, chunk = 24, kwargs...)

Each element of `cases` is a testset: the program of a zero-argument function has to compile, and give what the function gives in Julia (what it writes, and its result: see
`static_status`). An element is `name => f`, or a function (named by its name). The names in `broken` are the cases that don't work yet: when one does, it is an unexpected pass
that has to be taken off the list. With `TEST_FOLDED=1` a case fails if the compiler runs it (see `opaque`), unless it is in `folded_ok`.

The cases have to be independent of each other: they are compiled in groups of `chunk` (`batch = true`), each group as one program that runs them in turn, which is much faster than a
program for each; a group that does not pass is compiled again case by case, so that what is said of a case is what it would be on its own. `kwargs` are the options of the compilation.
"""
function check_cases(cases; broken = (), folded_ok = (), batch::Bool = true, chunk::Int = 24, kwargs...)
    named = [c isa Pair ? c : string(nameof(c)) => c for c in cases]
    isbroken = [name in broken for (name, _) in named]
    statuses = Vector{Tuple{Symbol,String}}(undef, length(named))
    todo = [i for i in eachindex(named) if !isbroken[i]]
    for group in Iterators.partition(todo, batch ? chunk : 1)
        fs = Function[named[i][2] for i in group]
        statuses[group] = StaticRuntime.static_status_batch(fs; kwargs...)
    end
    for (i, (name, f)) in enumerate(named)
        @testset "$name" begin
            if isbroken[i]
                @test_broken static_status(f; kwargs...)[1] == :ok
            else
                status, detail = statuses[i]
                @test (status, first(replace(string(detail), '\n' => ' '), 300)) == (:ok, "")
                # (with `TEST_FOLDED=1`) the program has to do what the case does: not print an answer that the compiler found, which `opaque` values are for
                if check_folded() && status == :ok && !(name in folded_ok)
                    n = program_size(f)
                    if get(ENV, "TEST_FOLDED", "") == "report" # (lists them, and goes on)
                        n > FOLDED_LIMIT || println("FOLDED ", name, " (", n, " instructions)")
                    else
                        @test n > FOLDED_LIMIT # the program of this case is only a constant
                    end
                end
            end
        end
    end
    return nothing
end
