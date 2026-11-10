# Sockets: the address types (`IPv4`, `IPv6`): made from numbers and from text, written, compared. (Sockets themselves, connections, are not supported: there are no tasks.)

@testset "Sockets" begin
    check_cases([
        "IPv4 from numbers"        => () -> (a = IPv4(opaque(127), 0, 0, 1); println(a); Int(a.host % 1000)),
        "IPv4 from text"           => () -> (a = parse(IPv4, opaque("10.20.30.40")); Int(a.host % 1000)),
        "IPv4 comparison"          => () -> (a = IPv4(opaque(1), 2, 3, 4); b = IPv4(opaque(1), 2, 3, 5); Int(a < b) + 2 * Int(a == b)),
        "IPv6 from text"           => () -> (a = parse(IPv6, opaque("::1")); Int(a.host % 1000)),
        "IPv6 written"             => () -> (a = IPv6(UInt128(opaque(0x20010db8) << 96)); println(a); 0),
        "address as an integer"    => () -> Int(UInt32(IPv4(opaque(192), 168, 0, 1)) % 1000),
    ])
end
