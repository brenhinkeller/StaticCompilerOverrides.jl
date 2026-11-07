using Test
include("corpus.jl")
include("testruntime.jl")
include("testembedding.jl")
include("testunicode.jl")
include("testtags.jl")
include("testobjectid.jl")
include("testshow.jl")
include("testheap.jl")
include("testblas.jl")
include("testdispatch.jl")

# Idioms that must compile to a standalone executable giving the same result as Julia.
# Known gaps, and what is needed. When one starts working, its `@test_broken` fails (as an
# unexpected pass): remove it from here, and it will be tested as supported.
const KNOWN_BROKEN = Dict(
    # the globals `stdout` and `stderr` have the abstract type `IO`: use `STDOUT`, `STDERR`
    "stderr"          => "`stderr` is a global of the abstract type `IO`: use `STDERR`",
    "@printf"         => "`@printf` without an `io` uses `stdout`: use `@printf(STDOUT, ...)`",
    "Printf.Format runtime" => "a `Printf.Format` is parsed from its string at run time, which is dynamic: make it once",
)

@testset "StaticCompilerOverrides" begin
    @testset "$name" for (name, f) in CORPUS
        if haskey(KNOWN_BROKEN, name)
            @test_broken static_status(f)[1] == :ok
        else
            status, detail = static_status(f)
            @test status == :ok
        end
    end
end

# The method table of this package does not contain StaticCompiler's overrides of the error
# helpers (which print and exit), so that errors can be caught; and StaticCompiler's does.
@testset "Method tables" begin
    SC = StaticCompilerOverrides.StaticCompiler
    domain_error(x::Int) = Base.Math.throw_complex_domainerror(:sqrt, x)
    function uses_quirk(table)
        ir = SC.GPUCompiler.JuliaContext() do ctx
            mod = static_llvm_module(domain_error, Tuple{Int}; method_table = table)
            try string(mod) finally SC.LLVM.dispose(mod) end
        end
        return occursin("requires a complex input", ir) # the message of the override in quirks.jl
    end
    @test !uses_quirk(StaticCompilerOverrides.method_table)
    @test uses_quirk(SC.method_table)
end

# Code that can't work as a standalone binary is rejected when compiling, rather than crashing
# (or silently misbehaving) when it is run, unless that is asked for
@testset "Strict mode" begin
    printing() = (println(Base.inferencebarrier(Any[1, "a"])); 1) # the type of the argument is not known when compiling (dynamic dispatch)
    main = StaticCompilerOverrides.make_main(printing)
    compile(; kwargs...) = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)); kwargs...)

    err = try compile(); nothing catch e; e end
    @test err isa UnsupportedCodeError
    @test !isempty(err.dynamic)
    @test occursin("ijl_apply_generic", sprint(showerror, err)) # says which, and what to do
    @test occursin("strict = false", sprint(showerror, err))
    @test "ijl_apply_generic" in undefined_symbols(printing)    # reported by the diagnostics too

    # the global `stderr` has the abstract type `IO`: the message says to use `STDERR`
    uses_stderr() = (println(stderr, "message"); 1)
    stderr_main = StaticCompilerOverrides.make_main(uses_stderr)
    err2 = try Base.invokelatest(compile_executable, stderr_main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(stderr_main))); nothing catch e; e end
    @test err2 isa UnsupportedCodeError
    @test occursin("STDERR", sprint(showerror, err2))
    @test !isempty(err2.pointers) # references to Julia objects by their address are reported too

    # strict = false compiles code that has dynamic dispatch anyway (and the call aborts the program if
    # it is reached); `allow` accepts specific runtime functions, and keeps the check for the rest
    dynamic() = (x = Base.inferencebarrier(3); Int(x + 1))
    dyn_main = StaticCompilerOverrides.make_main(dynamic)
    compile_dynamic(; kwargs...) = Base.invokelatest(compile_executable, dyn_main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(dyn_main)); kwargs...)
    @test_throws UnsupportedCodeError compile_dynamic()
    @test isfile(compile_dynamic(strict = false))
    @test isfile(compile_dynamic(allow = ("ijl_apply_generic",)))
    # (not enough when there are other problems, here references to Julia objects by their address)
    @test_throws UnsupportedCodeError Base.invokelatest(compile_executable, stderr_main, (Int, Ptr{Ptr{UInt8}}), mktempdir(),
                                                        string(nameof(stderr_main)); allow = ("ijl_apply_generic",))
    # code that is supported is not affected
    ok() = 1
    ok_main = StaticCompilerOverrides.make_main(ok)
    @test isfile(Base.invokelatest(compile_executable, ok_main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(ok_main))))
end
