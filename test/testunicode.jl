# The tables of the properties of characters (src/unicode.jl) agree with utf8proc for every code point

@testset "Unicode tables" begin
    U = StaticCompilerOverrides
    function mismatches()
        bad = 0
        for cp in UInt32(0):UInt32(0x10ffff)
            bad += U.lookup(U.CATEGORY, cp) != UInt8(@ccall utf8proc_category(cp::UInt32)::Cint)
            bad += U.lookup(U.CHARWIDTH, cp) != UInt8(@ccall utf8proc_charwidth(cp::UInt32)::Cint)
            bad += U.lookup(U.ISLOWER, cp) != !iszero(@ccall utf8proc_islower(cp::UInt32)::Cint)
            bad += U.lookup(U.ISUPPER, cp) != !iszero(@ccall utf8proc_isupper(cp::UInt32)::Cint)
            bad += UInt32(Int32(cp) + U.lookup(U.TOLOWER, cp)) != @ccall(utf8proc_tolower(cp::UInt32)::UInt32)
            bad += UInt32(Int32(cp) + U.lookup(U.TOUPPER, cp)) != @ccall(utf8proc_toupper(cp::UInt32)::UInt32)
            bad += UInt32(Int32(cp) + U.lookup(U.TOTITLE, cp)) != @ccall(utf8proc_totitle(cp::UInt32)::UInt32)
        end
        return bad
    end
    @test mismatches() == 0
end
