# BigInt and BigFloat: GMP and MPFR (libraries that the program calls, see `runtime/libraries.jl`) do the arithmetic, and the finalizer of each
# number (a C function: `__gmpz_clear`, `mpfr_clear`) is run by the collector when nothing refers to the number (see `runtime/heap.jl`).
#
# What is written here is what Base writes in a way that compiling can't follow: `round(T, x::BigFloat, r::RoundingMode)` calls
# `invoke` with a `Tuple` type that has a `where` in it, which is made when the program runs.

@device_override function Base.round(::Type{T}, x::BigFloat, r::RoundingMode) where T<:Union{Signed,Unsigned}
    return Base.round(T, x, convert(Base.MPFR.MPFRRoundingMode, r))
end

@device_override function Base.round(::Type{BigInt}, x::BigFloat, r::RoundingMode)
    return Base.round(BigInt, x, convert(Base.MPFR.MPFRRoundingMode, r))
end
