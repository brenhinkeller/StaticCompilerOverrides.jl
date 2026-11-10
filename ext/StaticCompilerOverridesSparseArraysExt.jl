# What a compiled program needs in SparseArrays' factorizations that Base does not give the program: SuiteSparse keeps a "common" (its settings and workspace) for each
# task, in the storage of the task, which a program does not have, and calls back into Julia when something fails, through a function that Julia makes a C function of.
# Here the program has one common for each size of integer, and the error is not given back by that function: the code of the failure is, in the `status` of the common,
# which is what `check_status` looks at (the message that Julia keeps there is what the function was for, so the exception says the code instead).
module StaticCompilerOverridesSparseArraysExt

using StaticCompilerOverrides: @device_override
using SparseArrays: SparseArrays
using SparseArrays: LibSuiteSparse
const ishermitian = SparseArrays.LinearAlgebra.ishermitian

const CHOLMOD = SparseArrays.CHOLMOD
const Common = Base.RefValue{CHOLMOD.cholmod_common}

const COMMON32 = Ref{Union{Nothing,Common}}(nothing)
const COMMON64 = Ref{Union{Nothing,Common}}(nothing)

function static_common(::Type{Int32})
    common = Ref(CHOLMOD.cholmod_common())
    result = CHOLMOD.cholmod_start(common)
    result == LibSuiteSparse.TRUE || error("failed to run `cholmod_start`")
    common[].print = 0 # (no printing from CHOLMOD)
    return common
end
function static_common(::Type{Int64})
    common = Ref(CHOLMOD.cholmod_common())
    result = CHOLMOD.cholmod_l_start(common)
    result == LibSuiteSparse.TRUE || error("failed to run `cholmod_l_start`")
    common[].print = 0
    return common
end

common_cache(::Type{Int32}) = COMMON32
common_cache(::Type{Int64}) = COMMON64

@device_override function CHOLMOD.getcommon(::Type{T}) where {T<:Union{Int32,Int64}}
    LibSuiteSparse.init_suitesparse()
    cache = common_cache(T)
    common = cache[]
    if common === nothing
        common = static_common(T)
        cache[] = common
    end
    return common::Common
end

@device_override function CHOLMOD.check_status(common::Common)
    status = common[].status
    if status < 0
        common[].status = CHOLMOD.CHOLMOD_OK
        throw(CHOLMOD.CHOLMODException(string("CHOLMOD error (status ", status, ")")))
    end
    return nothing
end

# `eltype(A) <: Union{Integer, Complex{<:Integer}}` makes the type that is the `Union` when the program runs (a `Complex{T} where T<:Integer` has a type variable in it)
Base.@assume_effects :foldable integer_eltype(::Type{T}) where {T} = T <: Union{Integer,Complex{<:Integer}}
@device_override SparseArrays._hermitian_solve(A::SparseArrays.AbstractSparseMatrixCSC) = !integer_eltype(eltype(A)) && ishermitian(A)

end
