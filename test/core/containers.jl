# Collections: vectors and matrices, `Dict` and `Set` (including constants that are tables hashed by address), `IdDict` and `IdSet`, and `deepcopy` of any struct. (Tuples are in `tuples.jl`.)

@testset "Vectors and matrices" begin
    check_cases([
    "Vector collect" => @opaque(() -> sum(collect(1:10))),
    "Vector push!" => @opaque(() -> (v = Int[]; for i in 1:10; push!(v, i); end; sum(v))),
    "Vector comprehension" => @opaque(() -> sum([i^2 for i in 1:10])),
    "Vector{Float64} ops" => @opaque(() -> sum(sort(Float64[3, 1, 2]) .* 2)),
    "Matrix"                => () -> sum(ones(3, 3) * ones(3, 3)),
    "Vector{Any}"           => () -> length(Any[1, "a", 2.0]),
        "splice! an element"      => () -> (v = [1, 2, 3, 4]; r = splice!(v, 2); println(r, v); r2 = splice!(v, 1, [7, 8, 9]); println(r2, v); 0),
        "splice! a range"         => () -> (v = [1, 2, 3, 4, 5]; r = splice!(v, 2:3, [9, 9, 9]); println(r, v); r = splice!(v, 2:4); println(r, v); r = splice!(v, 2:1, 5); println(r, v); 0),
        "splice! out of range"    => () -> (v = [1, 2]; try; splice!(v, 5); catch e; println(e isa BoundsError); end; 0),
        "reshape with a colon"   => () -> size(reshape(Float64[1, 2, 3, 4, 5, 6], :, 2), 1) + 10 * size(reshape(Float64[1, 2, 3, 4, 5, 6], 3, :), 2),
    ])
end

@testset "Dict and Set" begin
    check_cases([
    "Dict" => @opaque(() -> (d = Dict(1 => 2, 3 => 4); d[1] + d[3])),
    "Set" => @opaque(() -> length(Set([1, 2, 2, 3]))),
    "Dict of split words"   => () -> (d = Dict{String,Int}(); for w in split("a b a c b a"); d[w] = get(d, w, 0) + 1; end; d["a"]),
    ])
end

# Objects that are constants are copied into the binary, and have other addresses there. A table that was made with the
# addresses of its keys (`hash` of a mutable struct is its `objectid`, which is the address) would not find them.
mutable struct AddrKey; x::Int; end
struct AddrWrap; v::Vector{Int}; end                      # an immutable that refers to a mutable object: hashed by that object's address
mutable struct HashedKey; x::Int; end
Base.hash(k::HashedKey, h::UInt) = hash(k.x, h)           # its own hash: no address in it
Base.:(==)(a::HashedKey, b::HashedKey) = a.x == b.x

const ADDR_KEYS = [AddrKey(1), AddrKey(2)]
const ADDR_DICT = Dict(k => k.x for k in ADDR_KEYS)
const ADDR_SET = Set(ADDR_KEYS)
const ADDR_IDDICT = IdDict(k => k.x for k in ADDR_KEYS)
const WRAPS = [AddrWrap([1]), AddrWrap([2])]
const WRAP_DICT = Dict(w => 1 for w in WRAPS)
const HASHED_DICT = Dict(HashedKey(1) => 10, HashedKey(2) => 20)
const STRING_DICT = Dict("a" => 1, "b" => 2)
const EMPTY_IDDICT = IdDict{AddrKey,Int}()

addr_haskey() = haskey(ADDR_DICT, ADDR_KEYS[1])
addr_get() = get(ADDR_DICT, ADDR_KEYS[2], -1)
addr_in_set() = ADDR_KEYS[1] in ADDR_SET
addr_iddict() = get(ADDR_IDDICT, ADDR_KEYS[2], -1)
addr_wrapped() = get(WRAP_DICT, WRAPS[1], -1)
hashed_get() = get(HASHED_DICT, HashedKey(2), -1)
string_get() = STRING_DICT["b"]
empty_iddict() = (d = EMPTY_IDDICT; d[AddrKey(1)] = 5; length(d))
runtime_dict() = (d = Dict{AddrKey,Int}(); k = AddrKey(1); d[k] = 3; get(d, k, -1))

@testset "Dict, Set and IdDict constants that are hashed by address" begin
    for f in (addr_haskey, addr_get, addr_in_set, addr_iddict, addr_wrapped)
        status, detail = static_status(f)
        @testset "$(nameof(f))" begin
            @test status == :compile_error # (it is refused, and says why)
            @test occursin("address", string(detail))
        end
    end
    for f in (hashed_get, string_get, empty_iddict, runtime_dict)
        @testset "$(nameof(f))" begin
            @test static_status(f)[1] == :ok
        end
    end
end

@testset "IdDict and IdSet" begin
    check_cases([
        "keys are compared by identity" => @opaque(() -> (d = IdDict{Vector{Int},Int}(); a = [1]; b = [1]; d[a] = 1; d[b] = 2; d[a] + 10 * d[b] + 100 * length(d) + 1000 * Int(haskey(d, [1])))),
        "many keys, some deleted" => @opaque(() -> (d = IdDict{Vector{Int},Int}(); ks = [[i] for i in 1:40]; for (i, k) in enumerate(ks); d[k] = i; end; for k in ks[1:2:end]; delete!(d, k); end; s = 0; for (k, v) in d; s += k[1] * v; end; 100000 * length(d) + s)),
        "get!, pop!"                         => () -> (d = IdDict{Vector{Int},Int}(); a = [1]; get!(d, a, 3) + get!(() -> 9, d, a) + pop!(d, a) + length(d)),
        "Int keys" => @opaque(() -> (d = IdDict{Int,Int}(); for i in 1:100; d[i] = i * i; end; d[7] + length(d))),
        "IdSet"                              => () -> (s = Base.IdSet{Any}(); a = [1]; b = [1]; push!(s, a); push!(s, a); push!(s, b); pop!(s, a); length(s) * 10 + Int(b in s) + Int(a in s) * 100),
        "IdSet of many"                      => () -> (s = Base.IdSet{Any}(); xs = [[i] for i in 1:50]; for x in xs; push!(s, x); end; for x in xs[1:10]; delete!(s, x); end; length(s) + count(x -> x in s, xs)),
    ])
end

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

@testset "deepcopy" begin
    check_cases([
        "nested vectors" => @opaque(() -> (a = [[1, 2], [3]]; b = deepcopy(a); b[1][1] = 9; a[1][1] * 10 + b[1][1] + length(b[2]))),
        "a shared vector stays shared"       => () -> (x = [1, 2]; b = deepcopy([x, x]); b[1][1] = 7; b[2][1]),
        "a Dict" => @opaque(() -> (d = Dict(1 => [1, 2]); e = deepcopy(d); e[1][1] = 8; d[1][1] * 10 + e[1][1])),
        "strings"                            => () -> (a = ["a", "bc"]; length(deepcopy(a)[2])),
        # structs are copied field by field (each of its own type), with shared and cyclic references
        "immutable struct"                   => dc_immutable,
        "mutable struct"                     => dc_mutable,
        "nested structs"                     => dc_nested,
        "linked list"                        => dc_list,
        "cycle"                              => dc_cycle,
        "tree" => @opaque(dc_tree),
        "shared struct" => @opaque(dc_shared),
        "parametric struct"                  => dc_parametric,
        "Ref"                                => dc_ref,
    ])
end

# `deepcopy` of a struct is made field by field here, so a method of `deepcopy_internal` that a package defines for its type is not used
struct CustomCopy; v::Vector{Int}; end
Base.deepcopy_internal(x::CustomCopy, d::IdDict) = (haskey(d, x) ? d[x] : (d[x] = CustomCopy(Int[])))
struct PlainCopy; v::Vector{Int}; end
custom_deepcopy() = length(deepcopy(CustomCopy([1, 2, 3])).v)
plain_deepcopy() = length(deepcopy(PlainCopy([1, 2, 3])).v)
nested_custom_deepcopy() = length(deepcopy([CustomCopy([1, 2, 3])])[1].v)

@testset "deepcopy of a type that has a method of `deepcopy_internal`" begin
    for f in (custom_deepcopy, nested_custom_deepcopy)
        # (compiling says so, once for each type)
        status, detail = f === custom_deepcopy ? (@test_logs (:warn, r"deepcopy_internal") match_mode = :any static_status(f)) : static_status(f)
        @testset "$(nameof(f))" begin
            @test status in (:compile_error, :runtime_error) # (not the wrong answer)
        end
    end
    @test static_status(plain_deepcopy)[1] == :ok
end
