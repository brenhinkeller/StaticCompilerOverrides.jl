# Containers and values of types that are not known when compiling (found compiling StatsBase.jl): `IdDict` and `IdSet`, `deepcopy` of any struct (with shared and cyclic references),
# boxed floats and small integers, `reshape` with a colon, functions and `Colon()` that are shown, and `Symbol`s that the program makes.

symbol_name(x::Vector{Symbol}) = x[1]
mutable struct DeepNode
    value::Int
    next::Union{Nothing,DeepNode}
end

sb_case1() = (y = Base.inferencebarrier(1.5)::Float64; z = Base.inferencebarrier(Int8(3))::Int8; x = Any[y, 2.5f0, z]; Int(x[1] === y) + 10 * Int(x[2] === 2.5f0) + 100 * Int(x[3] === z) + 1000 * Int(x[1] === x[2]))
sb_case2() = (d = IdDict{Vector{Int},Int}(); a = [1]; b = [1]; d[a] = 1; d[b] = 2; d[a] + 10 * d[b] + 100 * length(d) + 1000 * Int(haskey(d, [1])))
sb_case3() = (d = IdDict{Vector{Int},Int}(); ks = [[i] for i in 1:40]; for (i, k) in enumerate(ks); d[k] = i; end; for k in ks[1:2:end]; delete!(d, k); end; s = 0; for (k, v) in d; s += k[1] * v; end; 100000 * length(d) + s)
sb_case4() = (d = IdDict{Vector{Int},Int}(); a = [1]; get!(d, a, 3) + get!(() -> 9, d, a) + pop!(d, a) + length(d))
sb_case5() = (d = IdDict{Int,Int}(); for i in 1:100; d[i] = i * i; end; d[7] + length(d))
sb_case6() = (a = [[1, 2], [3]]; b = deepcopy(a); b[1][1] = 9; a[1][1] * 10 + b[1][1] + length(b[2]))
sb_case7() = (x = [1, 2]; b = deepcopy([x, x]); b[1][1] = 7; b[2][1])
sb_case8() = (d = Dict(1 => [1, 2]); e = deepcopy(d); e[1][1] = 8; d[1][1] * 10 + e[1][1])
sb_case9() = (a = ["a", "bc"]; length(deepcopy(a)[2]))

struct DcInner; v::Vector{Float64}; end
struct DcImm; a::Vector{Int}; b::Int; end
mutable struct DcMut; a::Vector{Int}; b::Int; end
struct DcOuter; i::DcInner; names::Vector{String}; t::Tuple{Int,Vector{Int}}; end
mutable struct DcNode; v::Int; next::Union{Nothing,DcNode}; end
mutable struct DcTree; v::Int; kids::Vector{DcTree}; end
struct DcWrap{T}; x::T; end
dc_immutable() = (x = DcImm([1, 2], 3); y = deepcopy(x); y.a[1] = 9; x.a[1] * 10 + y.a[1] + y.b)
dc_mutable() = (x = DcMut([1, 2], 3); y = deepcopy(x); y.a[1] = 9; y.b = 7; x.a[1] * 10 + y.a[1] + y.b)
dc_nested() = (o = DcOuter(DcInner([1.0, 2.0]), ["a", "bc"], (1, [5, 6])); p = deepcopy(o); p.i.v[1] = 9.0; p.t[2][1] = 0; round(Int, o.i.v[1] * 10 + p.i.v[1] + o.t[2][1] + length(p.names[2])))
dc_list() = (n = DcNode(1, DcNode(2, nothing)); m = deepcopy(n); (m.next::DcNode).v = 5; ((n.next::DcNode).v * 10 + (m.next::DcNode).v) * 100 + m.v)
dc_cycle() = (n = DcNode(1, nothing); n.next = n; m = deepcopy(n); Int(m.next === m) + 10 * Int(m !== n))
dc_tree() = (t = DcTree(1, [DcTree(2, DcTree[]), DcTree(3, [DcTree(4, DcTree[])])]); u = deepcopy(t); u.kids[2].kids[1].v = 40; t.kids[2].kids[1].v + u.kids[2].kids[1].v + u.v)
dc_shared() = (i = DcInner([1.0]); a = [i, i]; b = deepcopy(a); b[1].v[1] = 5.0; round(Int, b[2].v[1]))
dc_parametric() = (w = DcWrap([1, 2, 3]); v = deepcopy(w); v.x[1] = 8; w.x[1] + v.x[1])
dc_ref() = (r = Ref([1, 2]); s = deepcopy(r); s[][1] = 5; r[][1] * 10 + s[][1])

@testset "Found compiling StatsBase.jl" begin
    @testset "reshape with a colon" begin
        @static_test size(reshape(Float64[1, 2, 3, 4, 5, 6], :, 2), 1)
        @static_test size(reshape(Float64[1, 2, 3, 4, 5, 6], 3, :), 2)
    end
    @testset "functions and Colon() are shown" begin
        @test static_status(() -> (print(sin); print(' '); print(:); print(' '); print(typeof(sin)); print(' '); println((:, identity)); 0)) == (:ok, "")
        @static_test ncodeunits(string(sin, identity, :))
    end
    @testset "Symbols that are not known when compiling" begin
        f = () -> (v = Base.inferencebarrier([:abcd, :ef])::Vector{Symbol}; s = symbol_name(v); ncodeunits(string("x ", s, " y")) + 100 * ncodeunits(sprint(print, s)))
        @static_test f()
        @test static_status(() -> (v = Base.inferencebarrier([:abcd])::Vector{Symbol}; print(symbol_name(v)); 0)) == (:ok, "")
    end
    @testset "boxed floats and small integers" begin
        boxed(x) = Base.inferencebarrier(x)
        @test static_result(() -> (a = boxed(1.5)::Float64; b = boxed(Float32(2.5))::Float32; c = boxed(Int8(3))::Int8; d = boxed(UInt16(4))::UInt16; Int(round(a + b)) + c + d)) == 11
        @static_test sb_case1()
    end
    @testset "IdDict" begin
        @static_test sb_case2()
        @static_test sb_case3()
        @static_test sb_case4()
        @static_test sb_case5()
    end
    @testset "deepcopy" begin
        @static_test sb_case6()
        @static_test sb_case7()
        @static_test sb_case8()
        @static_test sb_case9()
        # structs (copied field by field, each of its own type), with shared and cyclic references
        @static_test dc_immutable()
        @static_test dc_mutable()
        @static_test dc_nested()
        @static_test dc_list()
        @static_test dc_cycle()
        @static_test dc_tree()
        @static_test dc_shared()
        @static_test dc_parametric()
        @static_test dc_ref()
    end
end

@testset "IdSet" begin
    check_cases([
        "IdSet"                    => () -> (s = Base.IdSet{Any}(); a = [1]; b = [1]; push!(s, a); push!(s, a); push!(s, b); pop!(s, a); length(s) * 10 + Int(b in s) + Int(a in s) * 100),
        "IdSet of many"            => () -> (s = Base.IdSet{Any}(); xs = [[i] for i in 1:50]; for x in xs; push!(s, x); end; for x in xs[1:10]; delete!(s, x); end; length(s) + count(x -> x in s, xs)),
    ])
end

