# Coverage corpus: idioms of increasing "dynamism", each a zero-argument function whose
# result is compared between Julia and a compiled standalone executable.
using Random, Printf
if Base.find_package("StaticCompilerOverrides") === nothing
    include(joinpath(@__DIR__, "..", "src", "StaticCompilerOverrides.jl"))
    using .StaticCompilerOverrides
else
    using StaticCompilerOverrides
end

@noinline thrower(x::Int) = x > 0 ? throw(ArgumentError("boom")) : x
@noinline thrower3(x::Int) = x == 1 ? throw(ArgumentError("a")) : x == 2 ? throw(DomainError(x, "b")) : [1, 2, 3][x + 10]
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
    "isa on constants"      => () -> sum(classify, MIXED),
    "isa on boxed values"   => () -> (v = Any[]; push!(v, length(MIXED)); push!(v, "s" * "t"); push!(v, 2.5 * length(MIXED)); push!(v, Pt(1, 2.0)); push!(v, Other("o")); sum(x -> x isa Int ? 1 : x isa String ? 10 : x isa Float64 ? 100 : x isa Pt ? 1000 : x isa Other ? 10_000 : 100_000, v)),
    "isa Union"             => () -> (v = Union{Int,String,Nothing}[1, "a", nothing, 2]; sum(x -> x isa Int ? 1 : x isa String ? 10 : 100, v)),
    "catch typed 3 types"   => () -> (s = 0; for i in 1:3; s += try; thrower3(Base.inferencebarrier(i)); 0; catch e; e isa ArgumentError ? 1 : e isa DomainError ? 10 : e isa BoundsError ? 100 : 1000; end; end; s),
    "catch typed"           => () -> (try; thrower2(Base.inferencebarrier(2)); catch e; e isa DomainError ? 2 : 1; end),
    "BoundsError caught"    => () -> (try; [1, 2, 3][Base.inferencebarrier(5)::Int]; catch; 3; end),
    "InexactError caught"   => () -> (try; Int8(Base.inferencebarrier(300)::Int); catch; 4; end),
    "DivideError caught"    => () -> (try; div(1, Base.inferencebarrier(0)::Int); catch; 5; end),
    "error() caught"        => () -> (try; error("x"); catch; 7; end),
    "throw caught"          => () -> (try; throw(ArgumentError("x")); catch e; e isa ArgumentError ? 1 : 0; end),
    "global const Ref"      => () -> (GLOBAL_REF[] += 1),
    # printing
    "println Int"           => () -> (println(42); 1),
    "println String"        => () -> (println("hello"); 1),
    "print Float64"         => () -> (print(1.5); print(" "); println(2.0); 1),
    "println Bool/Char"     => () -> (println(true); println('x'); 1),
    "println mixed"         => () -> (println("a", 1, 'b', 2.5); 1),
    "interpolation"         => () -> (x = 3; println("x = $x, y = $(2x)"); 1),
    "println Vector"        => () -> (println([1, 2, 3]); 1),
    "println tuple"         => () -> (println((1, "a")); 1),
    "println Vector Float64" => () -> (println([1.5, 2.0]); 1),
    "println Vector String" => () -> (println(["a", "b"]); 1),
    "println Vector Bool"   => () -> (println([true, false]); 1),
    "println Vector{Any}"   => () -> (println(Any[1, "a", 2.0]); 1),
    "println Vector{UInt8}" => () -> (println(UInt8[1, 2]); 1),
    "println empty Vector"  => () -> (println(Int[]); 1),
    "println nested Vector" => () -> (println([[1, 2], [3]]); 1),
    "println Any nested"    => () -> (println(Any[1, Any["a", :b], nothing]); 1),
    "println Vector of Pt"  => () -> (println(Any[Pt(1, 2.0), (3, 4.5)]); 1),
    "repr Vector{Any}"      => () -> length(repr(Any[1, "a"])),
    "println Vector tuples" => () -> (println([(1, 2.5), (3, 4.5)]); 1),
    "println Dict-free pair" => () -> (println("a" => [1]); 1),
    "println tuple 1"       => () -> (println((1,)); 1),
    "println tuple nested"  => () -> (println((1, (2.5, 'c'), "s")); 1),
    "show Type"             => () -> (show(Int); println(); show(Vector{Float64}); println(); 1),
    "print Type"            => () -> (println(Int); println(Pair{Int,String}); 1),
    "println Pair"          => () -> (println(1 => 2); 1),
    "show"                  => () -> (show(7); println(); 1),
    "@show"                 => () -> (x = 5; @show x; 1),
    "print in loop"         => () -> (for i in 1:3; println(i); end; 1),
    "repr"                  => () -> length(repr([1, 2])),
    "string mixed"          => () -> length(string("a", 1, 'b', 2.5)),
    "sprint"                => () -> length(sprint(print, 12345)),
    "@printf"               => () -> (Printf.@printf("%d %.2f\n", 3, 2.5); 1),
    "stderr"                => () -> (println(stderr, "to stderr"); 1),
    "STDOUT"                => () -> (println(STDOUT, "explicit ", 1, ' ', 2.5); print(STDOUT, "x", 'y'); println(STDOUT); 1),
    "STDERR"                => () -> (println(STDERR, "to stderr"); print(STDERR, 1, 2, 3); println(STDERR); 1),
    "STDOUT show"           => () -> (show(STDOUT, 12); show(STDOUT, "str"); show(STDOUT, 'c'); println(STDOUT); 1),
    "STDOUT flush"          => () -> (print(STDOUT, "a"); flush(STDOUT); print(STDERR, "b"); flush(STDERR); println(STDOUT); 1),
    "@printf STDOUT"        => () -> (Printf.@printf(STDOUT, "%d %5.2f %s\n", 3, 2.5, "x"); 1),
    # printf of StaticTools (C's format specifiers); libc's stdout throughout, as `STDOUT` is
    "printf one"            => () -> (printf(c"%d\n", 42); printf(c"%5.2f|\n", 2.5); 1),
    "printf several"        => () -> (printf(c"%d + %d = %d\n", 1, 2, 3); printf(c"%s has %5.2f%% of %lld\n", c"x", 12.345, 10^12); 1),
    "printf types"          => () -> (printf(c"%d %d %u %x %.3f %.1f\n", Int8(-5), Int16(-300), UInt8(200), UInt16(255), 1.5f0, Float16(2.5)); 1),
    "printf String arg"     => () -> (printf(c"%s|%s|%s\n", "julia", c"static", string("a", 1)); 1),
    "printf in loop"        => () -> (for i in 1:4; printf(c"%d: %6.3f %s\n", i, i / 3, i % 2 == 0 ? c"even" : c"odd"); end; 1),
    "printf STDOUT STDERR"  => () -> (printf(STDOUT, c"out %d %s\n", 1, c"x"); printf(STDERR, c"err %d %s\n", 2, c"y"); printf(STDOUT, c"plain\n"); 1),
    "printf with STDOUT"    => () -> (print(STDOUT, "a "); printf(c"%d ", 1); print(STDOUT, "b "); printf(c"%d\n", 2); 1),
    "printf many args"      => () -> (printf(c"%d%d%d%d%d%d%d%d%d%d%d%d\n", 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2); printf(c"%d %f %d %f %s %lld\n", 1, 2.0, 3, 4.0, c"five", 6); 1),
    # Printf (Julia's own formats: `%d` is for any integer)
    "sprintf"               => () -> length(Printf.@sprintf("%d %5.2f %s %c %x|%-6s|%+d", 12, 3.14159, "str", 'z', 255, "ab", 5)),
    "sprintf Int64/Float32" => () -> length(Printf.@sprintf("%d %d %f %g %e", typemax(Int64), Int8(-3), 1.5f0, 0.1, 12345.678)),
    "@printf STDERR"        => () -> (Printf.@printf(STDERR, "e %d %s\n", 3, "x"); 1),
    "Printf.format"         => () -> (Printf.format(STDOUT, FORMAT, "pi", 3.14159); 1),
    "Printf.Format runtime" => () -> (Printf.format(STDOUT, Printf.Format("%s=%08.3f\n"), "pi", 3.14159); 1),
    "@printf unicode/%%"    => () -> (Printf.@printf(STDOUT, "%s 100%% %5s|\n", "é∑", "日本"); 1),
    "print String vararg"   => () -> (print("a", "b", "c", "d"); println(); println("x", 1, 2, 3, "y"); 1),
    "println nothing"       => () -> (println(); println(nothing); println(missing); 1),
    "println Symbol/Float32" => () -> (println(:sym, ' ', 1.5f0, ' ', 0x1f, ' ', -3); 1),
    "show String/Char"      => () -> (show("a \"quoted\"\n string"); show('x'); show('\n'); show('λ'); println(); 1),
    "show escapes"          => () -> (show("tab\there \u00e9 \u2200 \e"); println(); 1),
    "@show String"          => () -> (s = "abc"; @show s; c = 'z'; @show c; 1),
    "lowercase/uppercase"   => () -> (println(lowercase("HeLLo ÀÉÎ"), uppercase("HeLLo àéî"), uppercasefirst("élan")); 1),
    "isletter etc"          => () -> (cs = ('a', 'Z', '5', ' ', 'é', '∑', '\n'); println(count(isletter, cs), count(isuppercase, cs), count(islowercase, cs), count(isdigit, cs), count(isspace, cs)); 1),
    "textwidth"             => () -> (println(textwidth("abc"), textwidth("日本"), textwidth('é')); 1),
    "unicode"               => () -> (println("héllo ∑ 日本"); println('λ'); 1),
    "big output"            => () -> (for i in 1:2000; print(i, ' '); end; println(); 1),
    "Vector{Any}"           => () -> length(Any[1, "a", 2.0]),
]
const GLOBAL_REF = Ref(0)
const MIXED = Any[1, "str", 2.5, :sym, nothing, 'c', true, UInt8(7), (1, 2), [1, 2, 3]] # of different types
struct Pt; x::Int; y::Float64; end
StaticCompilerOverrides.add_show_candidates!(Pt, Tuple{Int,Float64})
struct Other; s::String; end
classify(x) = x isa Int ? 1 : x isa String ? 10 : x isa Float64 ? 100 : x isa Symbol ? 1000 : x isa Nothing ? 10_000 :
              x isa Char ? 100_000 : x isa Bool ? 1_000_000 : x isa UInt8 ? 10_000_000 : x isa Tuple ? 100_000_000 : 1_000_000_000
const FORMAT = Printf.Format("%s=%08.3f\n") # made once, as `@printf` does

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
