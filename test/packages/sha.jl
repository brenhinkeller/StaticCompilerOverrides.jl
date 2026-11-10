# SHA: the digests of strings and bytes, and HMAC, compared with Julia (the input is `opaque`, so that the program computes them).

@testset "SHA" begin
    check_cases([
        "sha1 of a string"         => () -> sum(Int, sha1(opaque("abc"))),
        "sha256 of a string"       => () -> sum(Int, sha256(opaque("The quick brown fox"))),
        "sha512 of a string"       => () -> sum(Int, sha512(opaque("abc"))),
        "sha256 of bytes"          => () -> sum(Int, sha256(UInt8[opaque(1), 2, 3, 4, 5])),
        "sha384 and sha224"        => () -> sum(Int, sha384(opaque("abc"))) + sum(Int, sha224(opaque("abc"))),
        "sha3_256"                 => () -> sum(Int, sha3_256(opaque("abc"))),
        "hex of a digest"          => () -> (h = bytes2hex(sha256(opaque("abc"))); println(h); length(h)),
        "hmac_sha256"              => () -> sum(Int, hmac_sha256(Vector{UInt8}(opaque("key")), Vector{UInt8}(opaque("message")))),
        "a long message"           => () -> sum(Int, sha256(fill(UInt8(opaque(7)), 1000))),
        "the context in pieces"    => () -> (ctx = SHA256_CTX(); update!(ctx, Vector{UInt8}(opaque("ab"))); update!(ctx, Vector{UInt8}(opaque("c"))); sum(Int, digest!(ctx))),
    ])
end
