# `show` of containers, types and structs (src/show.jl): the output of the compiled program is exactly that of
# Julia, and the strings that are made when compiling are what Base makes.

struct ShowPt; x::Int; y::Float64; end
struct ShowBox{T}; v::T; end
StaticCompilerOverrides.add_show_candidates!(ShowPt, Tuple{Int,Float64})

@testset "show of containers" begin
    S = StaticCompilerOverrides
    # (the output is compared with that of Julia by `static_status`)
    cases = [
        "Vector{Int}"      => () -> (println([1, 2, 3]); 1),
        "empty Vector"     => () -> (println(Int[]); println(Float64[]); println(String[]); 1),
        "Vector{Bool}"     => () -> (println([true, false]); 1),
        "Vector{String}"   => () -> (println(["a", "b\n"]); 1),
        "Vector{Symbol}"   => () -> (println([:a, :bc]); 1),
        "Vector{Char}"     => () -> (println(['a', '\'']); 1),
        "Vector{UInt8}"    => () -> (println(UInt8[1, 255]); 1),
        "Vector{Float32}"  => () -> (println(Float32[1.5, 2]); 1),
        "nested"           => () -> (println([[1, 2], [3]]); 1),
        "Vector{Any}"      => () -> (println(Any[1, "a", 2.5, :s, nothing, 'c', true]); 1),
        "nested Any"       => () -> (println(Any[1, Any["a", Any[2]]]); 1),
        "Vector of tuples" => () -> (println([(1, 2.5), (3, 4.5)]); 1),
        "tuples"           => () -> (println((1,)); println(()); println((1, "a", (2.5, 'c'))); 1),
        "Pair"             => () -> (println(1 => 2); println("a" => [1]); 1),
        "types"            => () -> (println(Int); println(Vector{Float64}); println(Pair{Int,String}); println(Union{Int,Nothing}); 1),
        "struct"           => () -> (println(ShowPt(1, 2.0)); 1),
        "struct in Any"    => () -> (println(Any[ShowPt(1, 2.0), (3, 4.5)]); 1),
        "parametric"       => () -> (println(1 => ShowBox(2)); 1),
        "Dict Int"         => () -> (println(Dict(1 => 2, 3 => 4)); 1),
        "Dict String"      => () -> (println(Dict("a" => 1, "b" => 2)); 1),
        "Dict Symbol"      => () -> (println(Dict(:a => 1.5)); 1),
        "Dict of vectors"  => () -> (println(Dict(1 => [1, 2])); 1),
        "empty Dict"       => () -> (println(Dict{Int,Int}()); println(Dict{String,Any}()); 1),
        "Dict with Any"    => () -> (d = Dict{Int,Any}(); d[1] = "a"; d[2] = 2.5; println(d); 1),
        "Set Int"          => () -> (println(Set([1, 2, 3])); 1),
        "Set String"       => () -> (println(Set(["a", "b"])); 1),
        "Set Float32"      => () -> (println(Set(Float32[1.5])); 1),
        "empty Set"        => () -> (println(Set{Int}()); 1),
        "Set in Vector"    => () -> (println([Set([1])]); 1),
        "repr Dict"        => () -> length(repr(Dict(1 => 2)) * repr(Set([1]))),
        "repr"             => () -> length(repr([1, 2]) * repr(Any[1, "a"]) * repr((1, 'c'))),
        "@show"            => () -> (x = [1, 2]; @show x; 1),
        "sprint show"      => () -> length(sprint(show, [1.5])),
        "string"           => () -> length(string([1, 2], (3, 4))),
    ]
    check_cases(cases)

    # the keys of a dictionary that are Strings are compared by their text (`===` of two Strings is `jl_egal__unboxed`),
    # also when they are not the same object
    @testset "String keys" begin
        keys_by_text() = (d = Dict("one" => 1, "two" => 2); n = 0;
                          for i in 1:2; n = 10 * n + d[i == 1 ? string("o", "ne") : "t" * "wo"]; end;
                          n + 100 * haskey(d, "thr" * "ee") + 1000 * (("a" * "b") == "ab") + 10000 * (Set(["x"]) == Set(["x" * ""])))
        @test static_result(keys_by_text) == keys_by_text()
    end

    # types and values that are not supported are rejected when compiling, or are an error when run (not wrong output)
    @testset "unsupported" begin
        @test static_status(() -> (println(Any[ShowBox(1)]); 1))[1] == :runtime_error # not in the candidates
        # (a symbol that is not an ASCII identifier is written as Julia writes it if the binary has it; one that the program makes is an error unless
        # it is certainly not an identifier or an operator: see `testsymbols.jl`)
        @test static_status(() -> (println(Any[Symbol("+")]); 1))[1] == :ok
        @test static_status(() -> (println(Any[Symbol("a+" * Base.inferencebarrier("b"))]); 1))[1] == :runtime_error # made by the program, and not clearly an operator or not
        @test static_status(() -> (println(Any[Dict(1 => 2)]); 1))[1] == :runtime_error # not in the candidates
        @test static_status(() -> (println(Base.inferencebarrier(Any[1])); 1))[1] == :runtime_error # (a call with an `Any`: over the types that are registered, which have not `Vector{Any}`)
    end

    # the strings that are made when compiling
    @testset "compile-time strings" begin
        @test S.host_string(show, Int) == "Int64"
        @test S.host_string(show, Vector{Float64}) == "Vector{Float64}"
        @test S.host_string(show, ShowPt) == "ShowPt"       # no `Main.`, as when Julia shows it to a stream
        @test S.host_string(print, Pair{Int,ShowPt}) == "Pair{Int64, ShowPt}"
        # `typeinfo_prefix` (the prefix that Base makes from the context): for each of the types of containers
        for x in ([1], Int[], Float64[], Any[1], Any[], String[], [(1, 2)], Union{Int,Nothing}[1], [ShowPt(1, 2.0)], [UInt8(1)])
            expected = Base.typeinfo_prefix(IOContext(IOBuffer()), x)
            got = S.typeinfo_prefix_static(Any, x)
            @test got == expected
        end
        # with a context that knows the type of the elements
        @test S.typeinfo_prefix_static(Vector{Int}, [1]) == Base.typeinfo_prefix(IOContext(IOBuffer(), :typeinfo => Vector{Int}), [1])
        @test S.typeinfo_prefix_static(Vector{Any}, Any[1]) == Base.typeinfo_prefix(IOContext(IOBuffer(), :typeinfo => Vector{Any}), Any[1])
    end

    # the stream types write like the streams of libc, and `sprint` makes the same text as Julia's
    @testset "streams" begin
        io = S.BufIO(IOBuffer())
        show(io, [1, 2, 3]); show(io, (1, "a")); show(io, Any[1, :a])
        @test String(take!(io.buf)) == sprint(show, [1, 2, 3]) * sprint(show, (1, "a")) * sprint(show, Any[1, :a])
        @test S.typeinfo_io(io, Int) isa IO
        @test get(S.typeinfo_io(io, Int), :typeinfo, Any) === Int
        @test get(io, :typeinfo, Any) === Any
    end
end
