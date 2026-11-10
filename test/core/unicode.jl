# Case, categories and widths of characters; the tables that are used (src/unicode.jl) are also compared with utf8proc's for every character (below).

@testset "Characters and strings" begin
    check_cases([
    "lowercase/uppercase"   => () -> (println(lowercase("HeLLo ÀÉÎ"), uppercase("HeLLo àéî"), uppercasefirst("élan")); 1),
    "isletter etc"          => () -> (cs = ('a', 'Z', '5', ' ', 'é', '∑', '\n'); println(count(isletter, cs), count(isuppercase, cs), count(islowercase, cs), count(isdigit, cs), count(isspace, cs)); 1),
    "textwidth"             => () -> (println(textwidth("abc"), textwidth("日本"), textwidth('é')); 1),
    "unicode"               => () -> (println("héllo ∑ 日本"); println('λ'); 1),
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
