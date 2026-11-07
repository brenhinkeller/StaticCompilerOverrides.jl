# Unicode properties without utf8proc.
#
# Julia gets the properties of characters (their category, width, upper and lower case, ...) from the
# utf8proc library, which is part of libjulia. These are functions of the code point alone, so
# instead we tabulate them (as runs of code points with the same value), when this package is
# compiled, with the version of utf8proc of the Julia that it is compiled for. The tables are then
# data of the programs that use them, like any other constant.

"""
    RunTable{T}

The values of a function of the code points `0:0x10ffff`, as the first code point of each of the runs
of code points with the same value (`starts`), and the values (`values`) of the runs.
"""
struct RunTable{T}
    starts::Vector{UInt32}
    values::Vector{T}
end

# the value of the code point `cp`
@inline lookup(table::RunTable, cp::UInt32) = @inbounds table.values[searchsortedlast(table.starts, cp)]

function RunTable(f, ::Type{T}) where {T}
    starts = UInt32[]
    values = T[]
    for cp in UInt32(0):UInt32(0x10ffff)
        value = f(cp)::T
        if isempty(values) || @inbounds(values[end]) != value
            push!(starts, cp)
            push!(values, value)
        end
    end
    return RunTable{T}(starts, values)
end

# the properties, by the functions of utf8proc that Base uses
const CATEGORY = RunTable(cp -> UInt8(Base.Unicode.category_code(cp)), UInt8)
const CHARWIDTH = RunTable(cp -> UInt8(@ccall utf8proc_charwidth(cp::UInt32)::Cint), UInt8)
const ISLOWER = RunTable(cp -> !iszero(@ccall utf8proc_islower(cp::UInt32)::Cint), Bool)
const ISUPPER = RunTable(cp -> !iszero(@ccall utf8proc_isupper(cp::UInt32)::Cint), Bool)
# the case mappings, as how far the code point is moved: runs are long (`'a':'z'` all move by 32)
const TOLOWER = RunTable(cp -> Int32(@ccall(utf8proc_tolower(cp::UInt32)::UInt32)) - Int32(cp), Int32)
const TOUPPER = RunTable(cp -> Int32(@ccall(utf8proc_toupper(cp::UInt32)::UInt32)) - Int32(cp), Int32)
const TOTITLE = RunTable(cp -> Int32(@ccall(utf8proc_totitle(cp::UInt32)::UInt32)) - Int32(cp), Int32)

@inline mapped(c::Char, table::RunTable{Int32}) = (cp = UInt32(c); Char(UInt32(Int32(cp) + lookup(table, cp))))

## The methods of Base that use utf8proc, for characters (`Char`). Those of other `AbstractChar`s
## are not covered: calls with these are rejected, as they would need utf8proc.

@device_override Base.Unicode.category_code(x::Integer) =
    x ≤ 0x10ffff ? Cint(lookup(CATEGORY, UInt32(x))) : Cint(30)

@device_override function Base.Unicode.textwidth(c::Char)
    u = reinterpret(UInt32, c)
    b = bswap(u)
    b < 0x7f && return Int(b >= 0x20) # ASCII, as in Base
    (Base.ismalformed(c) || Base.is_overlong_enc(u)) && return 1
    return Int(lookup(CHARWIDTH, UInt32(c)))
end

@device_override Base.Unicode.lowercase(c::Char) =
    isascii(c) ? ('A' <= c <= 'Z' ? c + 0x20 : c) : mapped(c, TOLOWER)
@device_override Base.Unicode.uppercase(c::Char) =
    isascii(c) ? ('a' <= c <= 'z' ? c - 0x20 : c) : mapped(c, TOUPPER)
@device_override Base.Unicode.titlecase(c::Char) =
    isascii(c) ? ('a' <= c <= 'z' ? c - 0x20 : c) : mapped(c, TOTITLE)

@device_override Base.Unicode.islowercase(c::Char) = Base.ismalformed(c) ? false : lookup(ISLOWER, UInt32(c))
@device_override Base.Unicode.isuppercase(c::Char) = Base.ismalformed(c) ? false : lookup(ISUPPER, UInt32(c))
