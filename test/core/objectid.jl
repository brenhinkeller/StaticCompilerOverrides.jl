# `objectid`, so that a struct can be the key of a `Dict` or a `Set` (src/objectid.jl): the number is exactly Julia's
# (a `Dict` made when compiling is in the binary, and looked up in with the numbers that the program makes), and what
# uses it compiles. Included by runtests.jl.

struct OidPt; x::Int; y::Float64; end
struct OidPad; a::UInt8; b::Int64; end
struct OidNamed; name::String; id::Int; end
struct OidNested; p::OidNamed; tag::Symbol; w::Int8; end
struct OidOpt; v::Union{Int,Nothing}; end
struct OidStrOpt; v::Union{String,Nothing}; end
struct OidEmpty; end
struct OidAny; v::Any; end
struct Oid3; a::UInt8; b::UInt8; c::UInt8; end
struct OidBig; a::NTuple{5,Int}; end
mutable struct OidMut; x::Int; end
const OID_DICT = Dict(OidNamed("a", 1) => 10, OidNamed("b", 2) => 20, OidNamed("c", 3) => 30)
const OID_PTS = Dict(OidPt(1, 2.0) => 1, OidPt(3, 4.0) => 2)

@testset "Objectid" begin
    S = StaticCompilerOverrides
    # the same number as Julia: for the sizes of values that are hashed in different ways (1, 2, 4, 8 and more bytes, of
    # which more than one block of the hash), padding, Unions, references, nested structs, and strings
    values = Any[1, UInt8(3), Int16(-4), Int32(7), 2.5, Float32(1.5), true, 'c', (1, 2), (1, "a"), (1, 2.0, 3),
        OidPt(1, 2.0), OidPad(1, 2), OidNamed("n", 1), OidNested(OidNamed("n", 1), :s, Int8(2)), OidOpt(1), OidOpt(nothing),
        OidStrOpt("a"), OidStrOpt(nothing), OidEmpty(), OidAny("x"), OidAny(1), Oid3(1, 2, 3), OidBig((1, 2, 3, 4, 5)),
        "hello", "", "x"^40, :sym, nothing, 1 => "a", (a = 1, b = 2.5), OidNamed("", 0)]
    @testset "$(typeof(v))" for v in values
        @test S.static_objectid(v) == objectid(v)
    end
    m = OidMut(1)
    @test S.static_objectid(m) == objectid(m)

    mk(s) = s * string(1)
    cases = [
        "struct key"       => () -> (d = Dict(OidNamed("a", 1) => 7); get(d, OidNamed(mk("a")[1:1], 1), 0) + 10 * get(d, OidNamed("a", 2), 0)),
        "many keys"        => () -> (d = Dict{OidNamed,Int}(); for i in 1:50; d[OidNamed(string(i), i)] = i; end;
                                     s = 0; for i in 1:50; s += get(d, OidNamed(string(i), i), 0); end; s + 1000 * length(d)),
        "bits struct key"  => () -> (d = Dict(OidPt(1, 2.0) => 5); get(d, OidPt(1, 2.0), 0) + 10 * get(d, OidPt(1, 3.0), 0)),
        "Set of structs"   => () -> (s = Set([OidNamed("a", 1), OidNamed("b", 2)]); (OidNamed(mk("a")[1:1], 1) in s) + 2 * (OidNamed("z", 1) in s)),
        "Union field key"  => () -> (d = Dict(OidOpt(1) => 1, OidOpt(nothing) => 2); get(d, OidOpt(1), 0) + 10 * get(d, OidOpt(nothing), 0)),
        "Dict in binary"   => () -> (get(OID_DICT, OidNamed(mk("a")[1:1], 1), 0) + 100 * get(OID_DICT, OidNamed("c", 3), 0) + 10000 * get(OID_DICT, OidNamed("d", 4), 0)),
        "bits Dict in binary" => () -> (get(OID_PTS, OidPt(3, 4.0), 0) + 10 * get(OID_PTS, OidPt(9, 9.0), 0)),
        "objectid"         => () -> (objectid(OidNamed("a", 1)) == objectid(OidNamed(mk("a")[1:1], 1))),
    ]
    check_cases(cases)
    # an `objectid` of a type that is not known when compiling is reported
    @test static_status(() -> Int(objectid(Base.inferencebarrier(OidNamed("a", 1))) % 2))[1] == :compile_error
end
