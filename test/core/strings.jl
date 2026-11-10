# Strings and characters: construction, interpolation, parsing and searching, `SubString`, and the properties of characters (case, category, width), compared with Julia, and the tables
# that those use (src/unicode.jl), compared with utf8proc's for every character.

@testset "Strings" begin
    check_cases([
    "String length"         => () -> length("hello" * " world"),
    "string(Int)" => @opaque(() -> length(string(12345))),
    "parse Int"             => () -> parse(Int, "42"),
    "parse Float64"         => () -> round(Int, parse(Float64, "3.14159") * 1000),
    "findfirst String"      => () -> first(findfirst("lo", "hello")), # a pointer into the middle of a string
    "SubString"             => () -> (s = SubString("hello world", 7, 11); length(s) + (s == "world")),
    "split loop"            => () -> (n = 0; for w in split("a b a c b a"); n += length(w); end; n), # a vector of structs with references, grown

        "string(1, x::Any)"       => () -> (println(string(1, any_value(5), 2.5, any_value("q"), :s, 'c')); 0),
        "interpolating an Any"    => () -> (x = any_value(7); println("x=$(1 + 1) y=$(x) z=$(any_value("w"))"); 0),
        "string of a few ints"    => () -> (println(string(1, 2, 3)); 0),
    ])
end

@testset "Characters" begin
    check_cases([
    "lowercase/uppercase"   => () -> (println(lowercase("HeLLo ÀÉÎ"), uppercase("HeLLo àéî"), uppercasefirst("élan")); 1),
    "isletter etc"          => () -> (cs = ('a', 'Z', '5', ' ', 'é', '∑', '\n'); println(count(isletter, cs), count(isuppercase, cs), count(islowercase, cs), count(isdigit, cs), count(isspace, cs)); 1),
    "textwidth"             => () -> (println(textwidth("abc"), textwidth("日本"), textwidth('é')); 1),
    "unicode" => @opaque(() -> (println("héllo ∑ 日本"); println('λ'); 1)),
    ])
end

# the tables of the properties of characters (src/unicode.jl) agree with utf8proc for every code point
@testset "Unicode tables" begin
    U = StaticCompilerOverrides
    function mismatches()
        bad = 0
        for cp in UInt32(0):UInt32(0x10ffff)
            bad += U.lookup(U.CATEGORY, cp) != UInt8(@ccall utf8proc_category(cp::UInt32)::Cint)
            bad += U.lookup(U.CHARWIDTH, cp) != UInt8(@ccall utf8proc_charwidth(cp::UInt32)::Cint)
            bad += U.lookup(U.ISLOWER, cp) != !iszero(@ccall utf8proc_islower(cp::UInt32)::Cint)
            bad += U.lookup(U.ISUPPER, cp) != !iszero(@ccall utf8proc_isupper(cp::UInt32)::Cint)
            bad += U.lookup(U.ISPRINT, cp) != Base.Unicode.isprint(Char(cp))
            bad += UInt32(Int32(cp) + U.lookup(U.TOLOWER, cp)) != @ccall(utf8proc_tolower(cp::UInt32)::UInt32)
            bad += UInt32(Int32(cp) + U.lookup(U.TOUPPER, cp)) != @ccall(utf8proc_toupper(cp::UInt32)::UInt32)
            bad += UInt32(Int32(cp) + U.lookup(U.TOTITLE, cp)) != @ccall(utf8proc_totitle(cp::UInt32)::UInt32)
        end
        return bad
    end
    @test mismatches() == 0
    # the characters that are not valid are not printable, as in Base (a `Char` is any 32 bits)
    @testset "isprint of any `Char`" begin
        rng = Random.Xoshiro(1)
        bad = 0
        for _ in 1:100_000
            c = reinterpret(Char, rand(rng, UInt32))
            ours = !Base.ismalformed(c) && U.lookup(U.ISPRINT, UInt32(c))
            bad += ours != Base.Unicode.isprint(c)
        end
        @test bad == 0
    end
end
