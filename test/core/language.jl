# The language: values of different types, `isa`, structs, closures and globals, and what is deprecated. (Strings are in `strings.jl`, numbers in `numbers.jl`, collections in
# `containers.jl`, tuples in `tuples.jl`, closures that are stored in collections in `closures.jl`.) Each case is a zero-argument function whose result (and what it writes) is compared
# between Julia and a compiled standalone executable.

mutable struct MutS; x::Int; end
const GLOBAL_REF = Ref(0)
const MIXED = Any[1, "str", 2.5, :sym, nothing, 'c', true, UInt8(7), (1, 2), [1, 2, 3]] # of different types
struct Pt; x::Int; y::Float64; end
StaticCompilerOverrides.add_show_candidates!(Pt, Tuple{Int,Float64})
struct Other; s::String; end
classify(x) = x isa Int ? 1 : x isa String ? 10 : x isa Float64 ? 100 : x isa Symbol ? 1000 : x isa Nothing ? 10_000 :
              x isa Char ? 100_000 : x isa Bool ? 1_000_000 : x isa UInt8 ? 10_000_000 : x isa Tuple ? 100_000_000 : 1_000_000_000

@testset "Language" begin
    check_cases([
    "closure" => @opaque(() -> (a = 5; f = x -> x + a; f(2))),
    "Ref" => @opaque(() -> (r = Ref(1); r[] += 1; r[])),
    "mutable struct" => @opaque(() -> (m = MutS(1); m.x += 1; m.x)),
    "Union return"          => () -> (x = rand(Bool) ? 1 : 1.0; Int(x)),
    "isa on constants" => @opaque(() -> sum(classify, MIXED)),
    "isa on boxed values"   => () -> (v = Any[]; push!(v, length(MIXED)); push!(v, "s" * "t"); push!(v, 2.5 * length(MIXED)); push!(v, Pt(1, 2.0)); push!(v, Other("o")); sum(x -> x isa Int ? 1 : x isa String ? 10 : x isa Float64 ? 100 : x isa Pt ? 1000 : x isa Other ? 10_000 : 100_000, v)),
    "isa Union" => @opaque(() -> (v = Union{Int,String,Nothing}[1, "a", nothing, 2]; sum(x -> x isa Int ? 1 : x isa String ? 10 : 100, v))),
    "global const Ref" => @opaque(() -> (GLOBAL_REF[] += 1)),
    ])
end

# values of types with fields or sizes that a box has to hold (a float, a small integer): kept in a `Vector{Any}`, taken out, and compared by `===`
boxed(x) = Base.inferencebarrier(x)
bx_identity() = (y = Base.inferencebarrier(1.5)::Float64; z = Base.inferencebarrier(Int8(3))::Int8; x = Any[y, 2.5f0, z]; Int(x[1] === y) + 10 * Int(x[2] === 2.5f0) + 100 * Int(x[3] === z) + 1000 * Int(x[1] === x[2]))
@testset "Boxed floats and small integers" begin
    check_cases([
        "boxed numbers of several types" => @opaque(() -> (a = boxed(1.5)::Float64; b = boxed(Float32(2.5))::Float32; c = boxed(Int8(3))::Int8; d = boxed(UInt16(4))::UInt16; Int(round(a + b)) + c + d)),
        "identity of boxed numbers"      => bx_identity,
    ])
end

Base.@deprecate deprecated_old(n) deprecated_new(n)
deprecated_new(n) = n + 100
@testset "Deprecated methods" begin
    # (the warning of a deprecated method, and the options of the Julia that runs, are not in the program)
    @test static_result(() -> deprecated_old(Base.inferencebarrier(1))) == 101
end
