using Test
include("corpus.jl")
include("testruntime.jl")
include("testembedding.jl")

# Idioms that must compile to a standalone executable giving the same result as Julia.
# Known gaps, and what is needed. When one starts working, its `@test_broken` fails (as an
# unexpected pass): remove it from here, and it will be tested as supported.
const KNOWN_BROKEN = Dict(
    "Matrix"          => "BLAS (`dgemm`) is not linked",
    "parse Int"       => "dynamic behavior in `tryparse_internal`",
    "catch typed"     => "objects have no type tag, so `isa` on a caught exception is wrong",
    # printing: there is no `stdout` yet, and `show` needs type information at run time
    (name => "no stdout: needs an `IO` for the standard streams (and type tags, for `show`)" for name in (
        "println Int", "println String", "print Float64", "println Bool/Char", "println mixed",
        "interpolation", "println Vector", "println tuple", "show", "@show", "print in loop",
        "repr", "@printf", "stderr",
    ))...,
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
    printing() = (println(42); 1) # needs `stdout`, and dynamic dispatch (`show`)
    main = StaticCompilerOverrides.make_main(printing)
    compile(; kwargs...) = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)); kwargs...)

    err = try compile(); nothing catch e; e end
    @test err isa UnsupportedCodeError
    @test !isempty(err.dynamic) && !isempty(err.pointers)
    @test occursin("ijl_apply_generic", sprint(showerror, err)) # says which, and what to do
    @test occursin("strict = false", sprint(showerror, err))
    @test "ijl_apply_generic" in undefined_symbols(printing)    # reported by the diagnostics too

    # strict = false compiles it anyway (and the calls abort the program if they are reached)
    @test isfile(compile(strict = false))
    # `allow` accepts specific runtime functions: not enough here, since there are others
    @test_throws UnsupportedCodeError compile(allow = ("ijl_apply_generic",))
    # code that is supported is not affected
    ok() = 1
    ok_main = StaticCompilerOverrides.make_main(ok)
    @test isfile(Base.invokelatest(compile_executable, ok_main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(ok_main))))
end
