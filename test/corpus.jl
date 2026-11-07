# Coverage corpus: idioms of increasing "dynamism", each a zero-argument function whose
# result is compared between Julia and a compiled standalone executable.
using Random
if Base.find_package("StaticCompilerOverrides") === nothing
    include(joinpath(@__DIR__, "..", "src", "StaticCompilerOverrides.jl"))
    using .StaticCompilerOverrides
else
    using StaticCompilerOverrides
end

@noinline thrower(x::Int) = x > 0 ? throw(ArgumentError("boom")) : x
@noinline thrower2(x::Int) = x == 1 ? throw(ArgumentError("a")) : throw(DomainError(x, "b"))
@noinline deep(n::Int) = n == 0 ? thrower(1) : [n; deep(n - 1)...][1] # allocates on the way
mutable struct MutS; x::Int; end
const CORPUS = [
    "arithmetic"            => () -> 3 * 4 + 1,
    "float math"            => () -> sin(1.0) + sqrt(2.0),
    "tuple/loop"            => () -> (s = 0; for x in (1, 2, 3); s += x; end; s),
    "closure"               => () -> (a = 5; f = x -> x + a; f(2)),
    "Ref"                   => () -> (r = Ref(1); r[] += 1; r[]),
    "Vector collect"        => () -> sum(collect(1:10)),
    "Vector push!"          => () -> (v = Int[]; for i in 1:10; push!(v, i); end; sum(v)),
    "Vector comprehension"  => () -> sum([i^2 for i in 1:10]),
    "Vector{Float64} ops"   => () -> sum(sort(Float64[3, 1, 2]) .* 2),
    "Matrix"                => () -> sum(ones(3, 3) * ones(3, 3)),
    "String length"         => () -> length("hello" * " world"),
    "string(Int)"           => () -> length(string(12345)),
    "parse Int"             => () -> parse(Int, "42"),
    "Dict"                  => () -> (d = Dict(1 => 2, 3 => 4); d[1] + d[3]),
    "Set"                   => () -> length(Set([1, 2, 2, 3])),
    "mutable struct"        => () -> (m = MutS(1); m.x += 1; m.x),
    "Union return"          => () -> (x = rand(Bool) ? 1 : 1.0; Int(x)),
    "rand"                  => () -> (rand(Int) == rand(Int) ? 0 : 1),
    "rand range"            => () -> (x = rand(1:10); 1 <= x <= 10 ? 1 : 0),
    "rand Float64"          => () -> (x = rand(); 0 <= x < 1 ? 1 : 0),
    "randn"                 => () -> (isfinite(randn()) ? 1 : 0),
    "rand array"            => () -> (v = rand(3); length(v) + (all(0 .<= v .< 1) ? 10 : 0)),
    "seed!"                 => () -> (Random.seed!(1); Int(rand(UInt64) >> 1)),
    "try/catch"             => () -> (try; thrower(Base.inferencebarrier(1)); catch; 7; end),
    "try no throw"          => () -> (try; thrower(Base.inferencebarrier(0)); catch; 7; end),
    "try/finally"           => () -> (r = Ref(0); try; r[] += 1; finally; r[] += 10; end; r[]),
    "catch and finally"     => () -> (r = Ref(0); try; try; thrower(Base.inferencebarrier(1)); finally; r[] += 10; end; catch; r[] += 1; end; r[]),
    "rethrow"               => () -> (try; try; thrower(Base.inferencebarrier(1)); catch; rethrow(); end; catch; 5; end),
    "nested try"            => () -> (try; try; thrower(Base.inferencebarrier(1)); catch; thrower(Base.inferencebarrier(2)); end; catch; 9; end),
    "throw through frames"  => () -> (try; deep(Base.inferencebarrier(5)); catch; -1; end),
    "catch in loop"         => () -> (s = 0; for i in 1:5; try; thrower(Base.inferencebarrier(i % 2)); catch; s += i; end; end; s),
    "catch typed"           => () -> (try; thrower2(Base.inferencebarrier(2)); catch e; e isa DomainError ? 2 : 1; end),
    "BoundsError caught"    => () -> (try; [1, 2, 3][Base.inferencebarrier(5)::Int]; catch; 3; end),
    "InexactError caught"   => () -> (try; Int8(Base.inferencebarrier(300)::Int); catch; 4; end),
    "DivideError caught"    => () -> (try; div(1, Base.inferencebarrier(0)::Int); catch; 5; end),
    "error() caught"        => () -> (try; error("x"); catch; 7; end),
    "throw caught"          => () -> (try; throw(ArgumentError("x")); catch e; e isa ArgumentError ? 1 : 0; end),
    "global const Ref"      => () -> (GLOBAL_REF[] += 1),
    "Vector{Any}"           => () -> length(Any[1, "a", 2.0]),
]
const GLOBAL_REF = Ref(0)

function run_corpus(; kwargs...)
    results = Tuple{String,Symbol,String}[]
    for (name, f) in CORPUS
        status, detail = try
            static_status(f; kwargs...)
        catch e
            :harness_error, first(sprint(showerror, e), 200)
        end
        push!(results, (name, status, detail))
        println(rpad(name, 24), rpad(status, 16), replace(detail, '\n' => ' '))
    end
    return results
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    run_corpus()
end
