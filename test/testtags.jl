# Type tags, `isa` on boxed values and on constants, and the lowering of the `switch`es on tags (src/tags.jl,
# src/runtime.jl). These are what depends most on how the Julia version lays out objects and generates code, so
# they are the tests to look at first when a new version of Julia breaks something. Included by runtests.jl.

struct TagA; x::Int; end
struct TagB; x::Float64; end
mutable struct TagC; x::Int; end
struct TagD{T}; x::T; end
struct EgPt; x::Int; y::Float64; end
struct EgNamed; name::String; id::Int; end
struct EgNested; p::EgNamed; tag::Symbol; w::Int8; end
struct EgOpt; v::Union{Int,Nothing}; end
mutable struct EgMut; x::Int; end
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
        @test static_result(abstracts) == abstracts()
    end

    @testset "type objects in the binary have the number of their fields" begin
        # code that indexes a struct with a Union of the types of its fields (a `Pair{String,Int}`) checks the
        # index against the length of `types` of the type, which was null (a crash) when it was left out
        pairs_loop() = (n = 0; for (k, v) in (TAG_P, TAG_Q); n += v + length(k); end; n)
        @test static_result(pairs_loop) == pairs_loop()
    end

    @testset "isa with abstract types and Unions on values of types that are only known when run" begin
        # (`ijl_subtype` of the runtime is a table, made when compiling, of which of the types in the binary are subtypes
        # of the types that are asked about)
        mixed(i) = Any[1, "a", :s, (1, 2), [1], 2.5, 'c', [1.0], nothing, 3 // 4, TagA(1), TagC(2)][i]
        chain(x) = x isa Number ? 1 : x isa AbstractString ? 2 : x isa Union{Symbol,Char} ? 3 : x isa Tuple ? 4 :
                   x isa AbstractVector{Int} ? 5 : x isa AbstractVector ? 6 : x isa Nothing ? 7 : x isa Union{TagA,TagB} ? 8 : 9
        classes() = (c = 0; for i in 1:12; c = 10c + chain(mixed(i)); end; c)
        @test static_result(classes) == classes()
        numbers() = (c = 0; for i in 1:12; x = mixed(i); c += (x isa Real) + 10 * (x isa Integer) + 100 * (x isa AbstractFloat) + 1000 * (x isa Number); end; c)
        @test static_result(numbers) == numbers()
        # an abstract exception type in a `catch`
        abstract_catch() = (c = 0; for i in 1:3
            c = 10c + try; i == 1 ? throw(ArgumentError("a")) : i == 2 ? throw(DomainError(1.0)) : throw(BoundsError());
                      catch e; e isa Exception ? (e isa ArgumentError ? 1 : 2) : 3; end
        end; c)
        @test static_result(abstract_catch) == abstract_catch()
        # a type that is computed when the program runs can't be answered
        mktype(i) = Any[Number, AbstractString][i]
        @test static_status(() -> (isa(mixed(1), mktype(1)) ? 1 : 0))[1] == :compile_error
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

# `===` of objects that are not the same one (for the keys of a `Dict`, for instance): `jl_egal__unboxed` of the runtime
# compares them by the plan that `egal_plan` makes for their type, which is in front of the layout of the type in the binary
@testset "egal" begin
    Runtime = StaticCompilerOverrides.Runtime
    # (equal, but not the same objects: the strings are made when the program runs, and the values are boxed)
    mk(s) = s * string(1)
    box(x) = Any[x][1]
    cases = [
        "tuples"         => () -> (a = box((mk("a"), 1)); (a === box((mk("a"), 1))) + 2 * (a === box((mk("a"), 2))) + 4 * (a === box((mk("b"), 1)))),
        "boxed numbers"  => () -> (a = box(300); (a === box(300)) + 2 * (a === box(301)) + 4 * (box(1.5) === box(1.5)) + 8 * (box(1.5) === box(-1.5)) + 16 * (box('c') === box('c')) + 32 * (box(Int8(3)) === box(Int8(3)))),
        "struct of bits" => () -> (a = box(EgPt(1, 2.0)); (a === box(EgPt(1, 2.0))) + 2 * (a === box(EgPt(1, 3.0)))),
        "with a string"  => () -> (a = box(EgNamed(mk("n"), 1)); (a === box(EgNamed(mk("n"), 1))) + 2 * (a === box(EgNamed(mk("m"), 1))) + 4 * (a === box(EgNamed(mk("n"), 2)))),
        "nested, symbol" => () -> (a = box(EgNested(EgNamed(mk("n"), 1), :s, Int8(2)));
                                   (a === box(EgNested(EgNamed(mk("n"), 1), :s, Int8(2)))) + 2 * (a === box(EgNested(EgNamed(mk("n"), 1), :t, Int8(2)))) + 4 * (a === box(EgNested(EgNamed(mk("x"), 1), :s, Int8(2))))),
        "mutable"        => () -> (a = box(EgMut(1)); (a === box(EgMut(1))) + 2 * (a === a)),
        "Dict, Set"      => () -> (d = Dict{Tuple{String,Int},Int}(); d[(mk("a"), 1)] = 5; d[(mk("b"), 2)] = 6;
                                   get(d, (mk("a"), 1), 0) + 10 * get(d, (mk("b"), 2), 0) + 100 * get(d, (mk("a"), 2), 0) + 1000 * ((mk("a"), 1) in Set([(mk("a"), 1)]))),
    ]
    @testset "$name" for (name, f) in cases
        @test static_status(f)[1] == :ok
    end

    @testset "plan" begin
        # (the number is the 8 bytes before the layout)
        ops(T) = (plan = Runtime.egal_plan(T); reinterpret(Int64, plan[1][plan[2]-7:plan[2]])[1])
        # the number of operations (negative for a mutable type): one comparison of bytes for a struct of numbers,
        # and for a string a comparison of the object it refers to
        @test ops(EgPt) == 1
        @test ops(EgNamed) == 2
        @test ops(EgMut) == -1
        @test ops(Int) == 1 && ops(Float64) == 1
        @test Runtime.egal_plan(AbstractString) === nothing
        # the layout in the plan is Julia's own
        bytes, off = Runtime.egal_plan(EgNamed)
        layout = unsafe_load(Ptr{Ptr{UInt8}}(pointer_from_objref(EgNamed) + fieldoffset(DataType, findfirst(==(:layout), fieldnames(DataType)))))
        @test bytes[off+1:end] == unsafe_wrap(Array, layout, length(bytes) - off)
    end
end

# What is in the binary depends on what the program uses (see "Binary size" in the manual): the plans for `===` of the types
# only if something compares objects, and the table of the types of the small tags only if an index into it is not known
@testset "Only what is used is in the binary" begin
    ir(f) = (main = StaticCompilerOverrides.make_main(f);
             GPUCompiler = StaticCompilerOverrides.StaticCompiler.GPUCompiler;
             GPUCompiler.JuliaContext() do ctx
                 mod = Base.invokelatest(static_llvm_module, main, Tuple{Int,Ptr{Ptr{UInt8}}})
                 text = string(mod)
                 LLVM.dispose(mod)
                 text
             end)
    keys_of(i) = Dict("a" * string(i) => 1)
    @testset "plans for ===" begin
        @test !occursin("static_egal_", ir(() -> (println(42); 0)))
        @test occursin("static_egal_", ir(() -> (d = keys_of(1); get(d, "a" * string(1), 0))))
    end
    @testset "table of the types of the small tags" begin
        # the types that code names are loaded one by one: no table
        @test !occursin("@jl_small_typeof = linkonce_odr", ir(() -> (println(42); 0)))
        # an index that is only known when run (the type of a boxed value) needs it
        boxed(i) = Any[1, "a", :s][i]
        @test occursin("@jl_small_typeof = linkonce_odr", ir(() -> (c = 0; for i in 1:3; c += (boxed(i) isa Number); end; c)))
    end
end
