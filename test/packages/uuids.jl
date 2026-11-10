# UUIDs: made from numbers and from text, written, parsed, and the random ones (their version and variant bits), compared with Julia.

@testset "UUIDs" begin
    check_cases([
        "from a number, as text"   => () -> (u = UUID(opaque(UInt128(0x123e4567e89b12d3a456426614174000))); println(u); length(string(u))),
        "parse"                    => () -> (u = parse(UUID, opaque("123e4567-e89b-12d3-a456-426614174000")); Int(u.value % 1000)),
        "version of a text"        => () -> Int(uuid_version(UUID(opaque("123e4567-e89b-12d3-a456-426614174000")))),
        "comparison"               => () -> (a = UUID(opaque(UInt128(1))); b = UUID(opaque(UInt128(2))); Int(a < b) + 2 * Int(a == b)),
        "a Dict with UUID keys"    => () -> (d = Dict(UUID(opaque(UInt128(1))) => 10, UUID(opaque(UInt128(2))) => 20); d[UUID(opaque(UInt128(2)))] + length(d)),
        "uuid4: version and variant" => () -> (u = uuid4(Random.Xoshiro(opaque(1))); println(u); Int(uuid_version(u)) + 10 * Int(u.value >> 62 & 0x3)), # (with a generator that is given: the default one reads the system's entropy with libuv: see `core/limitations.jl`)
        "uuid5 (a hash of a name)" => () -> (u = uuid5(UUID(opaque(UInt128(7))), opaque("name")); println(u); Int(uuid_version(u))),
    ])
end
