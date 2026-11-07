# Type tags, `isa` on boxed values and on constants, and the lowering of the `switch`es on tags (src/tags.jl,
# src/runtime.jl). These are what depends most on how the Julia version lays out objects and generates code, so
# they are the tests to look at first when a new version of Julia breaks something. Included by runtests.jl.
using Test
using LLVM

struct TagA; x::Int; end
struct TagB; x::Float64; end
mutable struct TagC; x::Int; end
struct TagD{T}; x::T; end
const TAG_P = "a" => 1
const TAG_Q = "bc" => 2

# one code for each of many types that are only known at run time: LLVM turns the chain of tests of the tag
# into a `switch` (which has to be lowered again once the types are addresses in the binary, in the order
# of the chain: a balanced search tree is wrong when the case values are not in the order of the cases)
tag_code(x) = x isa Int ? 1 : x isa Float64 ? 2 : x isa String ? 3 : x isa TagA ? 4 : x isa TagB ? 5 :
              x isa TagC ? 6 : x isa TagD{Int} ? 7 : x isa Symbol ? 8 : x isa Bool ? 9 : x isa Char ? 10 : 0
const TAG_VALUES = Any[1, 2.5, "s", TagA(1), TagB(2.0), TagC(3), TagD(4), :sym, true, 'c', nothing]
tag_all() = (c = 0; for i in 1:length(TAG_VALUES); c = 11 * c + tag_code(TAG_VALUES[i]); end; c)

@testset "Type tags" begin
    @testset "isa chain on boxed values of many types" begin
        # (the values are built in the program: not constants)
        built() = (v = Any[1, 2.5, "s" * string(1), TagA(1), TagB(2.0), TagC(3), TagD(4), :sym, true, 'c', nothing];
                   c = 0; for i in 1:length(v); c = 11 * c + tag_code(v[i]); end; c)
        @test static_result(built) == built()
        # (and the same values as constants of the program)
        @test static_result(tag_all) == tag_all()
    end

    @testset "isa with abstract types" begin
        abstracts() = (x = Any[1, 2.5, "s", (1, 2), [1], nothing]; c = 0;
                       for i in 1:length(x); y = x[i]; c = 3 * c + (y isa Number ? 1 : y isa AbstractString ? 2 : 0); end; c)
        # the constants are from Base's own objects: abstract `isa` reads the types, which are in the binary
        constants() = (c = 0; c += (3 isa Number) + 2 * ("s" isa AbstractString) + 4 * ((1, 2) isa Tuple) + 8 * (:a isa Symbol); c)
        @test static_result(constants) == constants()
        @test_broken static_status(abstracts)[1] == :ok # `isa` of a runtime type with an abstract type: needs `jl_subtype`
    end

    @testset "type objects in the binary have the number of their fields" begin
        # code that indexes a struct with a Union of the types of its fields (a `Pair{String,Int}`) checks the
        # index against the length of `types` of the type, which was null (a crash) when it was left out
        pairs_loop() = (n = 0; for (k, v) in (TAG_P, TAG_Q); n += v + length(k); end; n)
        @test static_result(pairs_loop) == pairs_loop()
    end

    @testset "type of an exception that is caught" begin
        thrown(i) = i == 1 ? throw(ArgumentError("a")) : i == 2 ? throw(DomainError(1.0)) : i == 3 ? throw(BoundsError()) : 0
        caught() = (c = 0; for i in 1:3
            c = 10 * c + try; thrown(i); 0; catch e; e isa ArgumentError ? 1 : e isa DomainError ? 2 : e isa BoundsError ? 3 : 9; end
        end; c)
        @test static_result(caught) == caught()
    end

    @testset "tags of the allocations of the program" begin
        # an object made by the program has the tag of its type: it is `isa` that type, and not another
        made() = (a = Ref(TagA(1)); b = Ref{Any}(TagB(2.0)); (b[] isa TagB) + 2 * (b[] isa TagA) + 4 * (a[] isa TagA))
        @test static_result(made) == made()
    end
end

@testset "Lowering of switches on type tags" begin
    Runtime = StaticCompilerOverrides.Runtime
    # a switch on `tag & -16`, with cases that share a destination, phis in the merge block and in the destination
    # of a case, and no cases
    ir = """
    define i64 @f(i64 %tag) {
    entry:
      %m = and i64 %tag, -16
      switch i64 %m, label %d [ i64 16, label %a
                                i64 48, label %b
                                i64 32, label %a
                                i64 -64, label %merge ]
    a:
      br label %merge
    b:
      br label %merge
    d:
      br label %merge
    merge:
      %r = phi i64 [ 1, %a ], [ 2, %b ], [ 3, %d ], [ 4, %entry ]
      ret i64 %r
    }
    define i64 @g(i64 %tag) {
    entry:
      %m = and i64 %tag, -16
      switch i64 %m, label %d []
    d:
      ret i64 7
    }
    """
    LLVM.@dispose ctx = LLVM.Context() begin
        mod = parse(LLVM.Module, ir)
        @test LLVM.verify(mod) === nothing
        switches = Runtime.type_switches(mod)
        @test length(switches) == 2
        foreach(Runtime.lower_switch!, switches)
        @test LLVM.verify(mod) === nothing # the phis have an entry for each edge
        @test isempty(Runtime.type_switches(mod))
        @test !occursin("switch", string(mod))
        @test count("icmp eq", string(mod)) == 4
    end
end
