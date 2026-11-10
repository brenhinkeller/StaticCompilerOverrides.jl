# Base64 and CRC32c, compared with Julia (the extension for `Base64` writes `encode` and `decode` without the tasks that the standard library uses).

@testset "Base64" begin
    check_cases([
        "Base64 encode"            => () -> (println(base64encode(any_value("hello world")), base64encode(UInt8[]), base64encode("a"), base64encode("ab")); 0),
        "Base64 decode"            => () -> (println(String(base64decode(any_value("aGVsbG8gd29ybGQ=")))); println(String(base64decode(any_value("aGVsbG8")))); 0),
        "Base64 round trip"        => () -> (b = Vector{UInt8}(1:200); Int(base64decode(base64encode(b)) == b)),
    ])
end

@testset "CRC32c" begin
    check_cases([
        "CRC32c"                   => () -> Int(crc32c(any_value("hello"))) + Int(crc32c(UInt8[1, 2, 3, 4, 5], 0x12345678)),
    ])
end

