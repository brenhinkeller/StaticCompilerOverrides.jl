using Test
include("corpus.jl")

# Idioms that must compile to a standalone executable giving the same result as Julia.
# Known gaps, and what is needed. When one starts working, its `@test_broken` fails (as an
# unexpected pass): remove it from here, and it will be tested as supported.
const KNOWN_BROKEN = Dict(
    "Matrix"          => "BLAS (`dgemm`) is not linked",
    "parse Int"       => "dynamic behavior in `tryparse_internal`",
    "catch typed"     => "objects have no type tag, so `isa` on a caught exception is wrong",
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
