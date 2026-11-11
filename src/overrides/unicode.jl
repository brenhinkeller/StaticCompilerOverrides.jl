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

"""
    BoolRunTable

A function of the code points that is `true` or `false`, as the first code point of each run: the runs alternate, so the
values are not kept (only whether the first is `true`). It is a fraction of the size of a [`RunTable`](@ref) of `Bool`s.
"""
struct BoolRunTable
    starts::Vector{UInt32}
    first::Bool
end

@inline lookup(table::BoolRunTable, cp::UInt32) = table.first ⊻ iseven(searchsortedlast(table.starts, cp))

function BoolRunTable(f)
    starts = UInt32[]
    last = nothing
    for cp in UInt32(0):UInt32(0x10ffff)
        value = f(cp)::Bool
        value === last && continue
        push!(starts, cp)
        last = value
    end
    # (`starts[1]` is 0: the code points are all in a run)
    return BoolRunTable(starts, f(UInt32(0)))
end

# the properties, by the functions of utf8proc that Base uses
const CATEGORY = RunTable(cp -> UInt8(Base.Unicode.category_code(cp)), UInt8)
const CHARWIDTH = RunTable(cp -> UInt8(@ccall utf8proc_charwidth(cp::UInt32)::Cint), UInt8)
const ISLOWER = BoolRunTable(cp -> !iszero(@ccall utf8proc_islower(cp::UInt32)::Cint))
const ISUPPER = BoolRunTable(cp -> !iszero(@ccall utf8proc_isupper(cp::UInt32)::Cint))
# (`isprint` is a test of the category, which is a table that is five times as large: this is what showing a string needs)
const ISPRINT = BoolRunTable(cp -> Base.Unicode.UTF8PROC_CATEGORY_LU <= Base.Unicode.category_code(cp) <= Base.Unicode.UTF8PROC_CATEGORY_ZS)
# (`isspace` is a test of the category too, of three categories, and it is asked of every `parse` of a number and every `strip`: a table of its own is a few bytes)
const ISSPACE = BoolRunTable(cp -> isvalid(Char, cp) && Base.isspace(Char(cp)))
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
# (the comparisons of a `Char` are those of its bytes, as in Base: a character that is not valid can be between `'\t'` and `'\r'`, and is a space then)
@device_override Base.Unicode.isspace(c::Char) =
    c == ' ' || '\t' <= c <= '\r' || c == '\u85' || '\ua0' <= c && !Base.ismalformed(c) && lookup(ISSPACE, UInt32(c))
@device_override Base.Unicode.isprint(c::Char) = Base.ismalformed(c) ? false : lookup(ISPRINT, UInt32(c))

# The two letters of the category of a character (`Lu`, `Nd`, ...), which `show(io, MIME"text/plain"(), c)` of a `Char` writes (`display('a')`), are asked of utf8proc by
# Base; here they come from the number of the category (see `category_code` above), in the order of utf8proc's `UTF8PROC_CATEGORY_*`.
const CATEGORY_ABBREVIATIONS = ("Cn", "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
                                "Sm", "Sc", "Sk", "So", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co")
@device_override Base.Unicode.category_abbrev(c::AbstractChar) = @inbounds CATEGORY_ABBREVIATIONS[Base.Unicode.category_code(c) + 1]
