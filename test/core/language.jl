# Idioms of Base and of the language, each a zero-argument function whose result (and what it writes) is compared between Julia and a compiled standalone executable.

mutable struct MutS; x::Int; end
const GLOBAL_REF = Ref(0)
const MIXED = Any[1, "str", 2.5, :sym, nothing, 'c', true, UInt8(7), (1, 2), [1, 2, 3]] # of different types
const UNION_VEC = Union{Int,Nothing}[1, nothing, 2, 3] # (a union of types without references: a byte for the type of each)
const UNION_VEC_SHIFTED = (v = Union{Int8,Float32,Nothing}[Int8(1), 2.5f0, nothing, Int8(4)]; popfirst!(v); v) # (its reference is an element number)
struct Pt; x::Int; y::Float64; end
StaticCompilerOverrides.add_show_candidates!(Pt, Tuple{Int,Float64})
struct Other; s::String; end
classify(x) = x isa Int ? 1 : x isa String ? 10 : x isa Float64 ? 100 : x isa Symbol ? 1000 : x isa Nothing ? 10_000 :
              x isa Char ? 100_000 : x isa Bool ? 1_000_000 : x isa UInt8 ? 10_000_000 : x isa Tuple ? 100_000_000 : 1_000_000_000

@testset "Language and Base" begin
    check_cases([
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
    "isa on constants"      => () -> sum(classify, MIXED),
    "isa on boxed values"   => () -> (v = Any[]; push!(v, length(MIXED)); push!(v, "s" * "t"); push!(v, 2.5 * length(MIXED)); push!(v, Pt(1, 2.0)); push!(v, Other("o")); sum(x -> x isa Int ? 1 : x isa String ? 10 : x isa Float64 ? 100 : x isa Pt ? 1000 : x isa Other ? 10_000 : 100_000, v)),
    "isa Union"             => () -> (v = Union{Int,String,Nothing}[1, "a", nothing, 2]; sum(x -> x isa Int ? 1 : x isa String ? 10 : 100, v)),
    "global const Ref"      => () -> (GLOBAL_REF[] += 1),
    "Vector{Any}"           => () -> length(Any[1, "a", 2.0]),
    # found by surveying ordinary Base code
    "findfirst String"      => () -> first(findfirst("lo", "hello")), # a pointer into the middle of a string
    "SubString"             => () -> (s = SubString("hello world", 7, 11); length(s) + (s == "world")),
    "parse Float64"         => () -> round(Int, parse(Float64, "3.14159") * 1000),
    "split loop"            => () -> (n = 0; for w in split("a b a c b a"); n += length(w); end; n), # a vector of structs with references, grown
    "Dict of split words"   => () -> (d = Dict{String,Int}(); for w in split("a b a c b a"); d[w] = get(d, w, 0) + 1; end; d["a"]),
    "time_ns/time"          => () -> (t = time_ns(); Int(time_ns() >= t) + Int(time() > 1e9)),
    "nthreads"              => () -> Threads.nthreads(),
    "const Vector{Union{Int,Nothing}}" => () -> sum(x -> x === nothing ? 0 : x, UNION_VEC),
    "const Union vector, shifted" => () -> (s = 0.0; for x in UNION_VEC_SHIFTED; s += x === nothing ? 100 : Float64(x); end; s),
    "ccall with a Cstring literal" => () -> Int(ccall(:strlen, Csize_t, (Cstring,), "hello")), # the address of the literal is passed as a number
    ])
end

@testset "Base" begin
    check_cases([
        "string(1, x::Any)"       => () -> (println(string(1, any_value(5), 2.5, any_value("q"), :s, 'c')); 0),
        "interpolating an Any"    => () -> (x = any_value(7); println("x=$(1 + 1) y=$(x) z=$(any_value("w"))"); 0),
        "string of a few ints"    => () -> (println(string(1, 2, 3)); 0),
        "splice! an element"      => () -> (v = [1, 2, 3, 4]; r = splice!(v, 2); println(r, v); r2 = splice!(v, 1, [7, 8, 9]); println(r2, v); 0),
        "splice! a range"         => () -> (v = [1, 2, 3, 4, 5]; r = splice!(v, 2:3, [9, 9, 9]); println(r, v); r = splice!(v, 2:4); println(r, v); r = splice!(v, 2:1, 5); println(r, v); 0),
        "splice! out of range"    => () -> (v = [1, 2]; try; splice!(v, 5); catch e; println(e isa BoundsError); end; 0),
        "sleep"                   => () -> (t = time(); sleep(0.05); println(time() - t >= 0.04); 0),
        "sleep with a bad time"   => () -> (try; sleep(-1); catch e; println(e isa ArgumentError); end; 0),
        "iterating a mixed tuple" => () -> (s = 0; for x in (1, 2.5, 3); s += x; end; println(s); 0),
        "summary of an array"     => () -> (println(summary([1, 2])); println(summary([1.0 2.0])); 0),
        "a type to an IOBuffer"   => () -> (io = IOBuffer(); print(io, Vector{Int}); println(String(take!(io))); 0),
    ])
end

@testset "Broadcasts and products of complex numbers and rationals" begin
    Z = [0.6 0.8; -0.8 0.6]
    C = ComplexF64[4 1im; 0 3]
    Q = Rational{Int}[1 2; 3 4]
    check_cases([
        "abs. of a complex matrix"   => () -> r6(sum(abs.(C))),
        "real and imag"              => () -> r6(sum(real(C)) + sum(imag(C))),
        "complex .* complex"         => () -> r6(sum(abs, C .* C)),
        "complex .+ 1"               => () -> r6(sum(abs, C .+ 1)),
        "conj."                      => () -> r6(sum(abs, imag.(conj.(C)))),
        "a real by a complex matrix" => () -> r6(sum(abs, Z * C)),
        "a complex by a real matrix" => () -> r6(sum(abs, C * Z)),
        "a rational matrix"          => () -> (R = Q .+ 1; Int(sum(numerator, R)) * 100 + Int(sum(denominator, R))),
        "a rational product"         => () -> (R = Q * Q; Int(sum(numerator, R)) * 100 + Int(sum(denominator, R))),
        "complex vectors"            => () -> r6(sum(abs.(ComplexF64[1, 2im] .* 2))),
    ])
end

