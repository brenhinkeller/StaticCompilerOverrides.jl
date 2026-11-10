# Parsers.jl (version 3): numbers, `Bool`, UUIDs, dates and big numbers from text and from byte spans, `tryparse`, errors, and the tokenizer `parsenext` and the kernels that a reader of files is made of.
using Parsers

function parsers_field_sum(s)
    b = codeunits(s)
    pos = 1
    n = length(b)
    total = 0
    while pos <= n
        (v, next, code) = Parsers.parsenext(Int, b, pos, n)
        total += v
        pos = next + 1 # (the comma)
    end
    return total
end

function parsers_float_sum(s)
    b = codeunits(s)
    pos = 1
    n = length(b)
    total = 0.0
    while pos <= n
        (v, next, code) = Parsers.parsenext(Float64, b, pos, n)
        total += v
        pos = next + 1
    end
    return total
end

@testset "Parsers.jl" begin
    @testset "Integers, floats and Bool" begin
        check_cases([
            "Int"                   => () -> Parsers.parse(Int, opaque("12345")),
            "negative Int"          => () -> Parsers.parse(Int, opaque("-98")) + 1000,
            "Int8, UInt16"          => () -> Int(Parsers.parse(Int8, opaque("12"))) + Int(Parsers.parse(UInt16, opaque("500"))),
            "Int128"                => () -> Int(Parsers.parse(Int128, opaque("123456789012345678901234567890")) % 1000),
            "hex prefix, base"      => () -> Parsers.parse(Int, opaque("0x1f")) * 100 + Parsers.parse(Int, opaque("z"); base = 36),
            "groupmark"             => () -> Parsers.parse(Int, opaque("1,000,000"); groupmark = ','),
            "surrounding whitespace" => () -> Parsers.parse(Int, opaque("  7 ")) + 10,
            "Float64"               => () -> r6(Parsers.parse(Float64, opaque("3.14159"))),
            "Float64 with an exponent" => () -> r6(Parsers.parse(Float64, opaque("1.5e3"))),
            "Float32, Float16"      => () -> r6(Parsers.parse(Float32, opaque("2.5"))) + r6(Parsers.parse(Float16, opaque("0.5"))),
            "Inf and NaN"           => () -> (a = Parsers.parse(Float64, opaque("Inf")); b = Parsers.parse(Float64, opaque("NaN")); Int(isinf(a)) + 10 * Int(isnan(b))),
            "decimal comma"         => () -> r6(Parsers.parse(Float64, opaque("101,101"); decimal = ',')),
            "hexadecimal float"     => () -> r6(Parsers.parse(Float64, opaque("0x1.8p1"))),
            "the bits of 0.1"       => () -> reinterpret(Int, Parsers.parse(Float64, opaque("0.1"))) % 1000003,
            "many digits"           => () -> reinterpret(Int, Parsers.parse(Float64, opaque("123456789.123456789"))) % 1000003,
            "tiny and huge"         => () -> (a = Parsers.parse(Float64, opaque("1e-300")); b = Parsers.parse(Float64, opaque("1e300")); Int(a < 1e-299) + 10 * Int(b > 1e299)),
            "Bool"                  => () -> Int(Parsers.parse(Bool, opaque("true"))) + 10 * Int(Parsers.parse(Bool, opaque("false"))) + 100 * Int(Parsers.parse(Bool, opaque("1"))),
            "Bool with other spellings" => () -> Int(Parsers.parse(Bool, opaque("yes"); trues = ["yes"], falses = ["no"])),
        ])
    end

    @testset "Dates, UUIDs and big numbers" begin
        check_cases([
            "Date"                  => () -> (d = Parsers.parse(Date, opaque("2018-01-20")); month(d) * 100 + day(d)),
            "Date with a format"    => () -> (d = Parsers.parse(Date, opaque("01/20/2018"); dateformat = "mm/dd/yyyy"); month(d) * 100 + day(d)),
            "DateTime"              => () -> (d = Parsers.parse(DateTime, opaque("2024-01-02T03:04:05.125")); hour(d) * 10000 + second(d) * 100 + millisecond(d) % 100),
            "Time"                  => () -> (t = Parsers.parse(Time, opaque("1:05 PM"); dateformat = "I:MM p"); hour(t) * 100 + minute(t)),
            "UUID"                  => () -> Int(Parsers.parse(UUID, opaque("123e4567-e89b-12d3-a456-426614174000")).value % 1000),
            "BigInt"                => () -> Int(Parsers.parse(BigInt, opaque("123456789012345678901234567890")) % 1000),
            "BigFloat"              => () -> r6(Float64(Parsers.parse(BigFloat, opaque("0.1")))),
        ])
    end

    @testset "tryparse, errors, spans and the kernels" begin
        check_cases([
            "tryparse"              => () -> (x = Parsers.tryparse(Int, opaque("42")); y = Parsers.tryparse(Int, opaque("4x2")); (x === nothing ? -1 : x) * 10 + (y === nothing ? -1 : y)),
            "tryparse of a float, of an overflow" => () -> (x = Parsers.tryparse(Float64, opaque("abc")); y = Parsers.tryparse(Int8, opaque("300")); Int(x === nothing) + 10 * Int(y === nothing)),
            "an error is thrown"    => () -> (try; Parsers.parse(Int, opaque("abc")); 0; catch e; e isa ArgumentError ? 1 : 2; end),
            "a span of bytes"       => () -> (b = Vector{UInt8}(opaque("12,3.5e2,true")); Parsers.parse(Int, b, 1, 2) * 1000 + r6(Parsers.parse(Float64, b, 4, 8)) % 1000 + Int(Parsers.tryparse(Bool, b, 10, 13))),
            "a SubString"           => () -> Parsers.parse(Int, SubString(opaque("xx42yy"), 3, 4)),
            "parsenext"             => () -> (b = Vector{UInt8}(opaque("12,3.5e2,true")); (v, next, code) = Parsers.parsenext(Float64, b, 4, length(b)); r6(v) + next),
            "the code of parsenext" => () -> (b = Vector{UInt8}(opaque("abc")); (v, next, code) = Parsers.parsenext(Int, b, 1, 3); Int(code == Parsers.RC_INVALID) + next),
            "the kernel for integers" => () -> (b = codeunits(opaque("9876")); (v, code) = Parsers.parseint(Int, b, 1, 4); v + Int(code == Parsers.RC_OK)),
            "the kernel for floats" => () -> (b = codeunits(opaque("2.75")); (v, code) = Parsers.parsefloat(Float64, b, 1, 4, UInt8('.')); r6(v)),
            "a loop over the fields of a line" => () -> parsers_field_sum(opaque("1,2,3,4,5,6,7,8,9,10")),
            "a loop over floats"    => () -> r6(parsers_float_sum(opaque("1.5,2.25,3.125"))),
        ])
    end
end
