# What a compiled program needs in LinearAlgebra that Base's code does not give it.
#
# `LAPACK.gees!` (the Schur factorization of a real matrix) and `LAPACK.trsen!` (the reordering of one) return eigenvalues that are real or complex depending on
# the matrix, so their results are a `Union` of two tuple types, and `schur!` and `ordschur` splat that into `Schur(...)`, which is a call of `Core._apply_iterate`
# over a `Union` that cannot be compiled. Indexing the result instead is split by the compiler into the two cases, so `schur` returns a `Union` of two `Schur`
# types, as it does in Julia.
module StaticRuntimeLinearAlgebraExt

using StaticRuntime: @device_override
using LinearAlgebra: LinearAlgebra, Schur, LAPACK, BlasFloat, BlasInt

@device_override function LinearAlgebra.schur!(A::StridedMatrix{<:Union{Float32, Float64, ComplexF32, ComplexF64}})
    result = LAPACK.gees!('V', A)
    return Schur(result[1], result[2], result[3])
end

@device_override function LinearAlgebra._ordschur!(T::StridedMatrix{Ty}, Z::StridedMatrix{Ty}, select::Union{Vector{Bool}, BitVector}) where {Ty<:BlasFloat}
    result = LAPACK.trsen!(convert(Vector{BlasInt}, select), T, Z)
    return (result[1], result[2], result[3])
end

@device_override function LinearAlgebra.ordschur(schur::Schur, select::Union{Vector{Bool}, BitVector})
    result = LinearAlgebra._ordschur(schur.T, schur.Z, select)
    return Schur(result[1], result[2], result[3])
end

end
