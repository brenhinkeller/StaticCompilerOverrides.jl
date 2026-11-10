# StaticArrays.jl: fixed-size vectors and matrices (immutable and mutable), their arithmetic, linear algebra and factorizations, and structs that are vectors of their fields.
using StaticArrays

struct Pt3 <: FieldVector{3,Float64}
    x::Float64
    y::Float64
    z::Float64
end

@testset "StaticArrays.jl" begin
    @testset "Vectors" begin
        check_cases([
            "sum"                => @opaque(() -> r6(sum(SVector(1.0, 2.0, 3.0)))),
            "dot, norm, broadcast" => @opaque(() -> (v = SVector(1.0, 2.0, 3.0); w = SVector(4.0, 5.0, 6.0); r6(dot(v, w) + norm(v + w) + sum(v .* w)))),
            "cross"              => @opaque(() -> r6(sum(cross(SVector(1.0, 2.0, 3.0), SVector(4.0, 5.0, 6.0))))),
            "of Int"             => @opaque(() -> (v = SVector{4,Int}(1, 2, 3, 4); sum(v) * 10 + v[end])),
            "map and broadcast"  => @opaque(() -> (v = SVector(1.0, 2.0, 3.0); r6(sum(map(x -> x^2, v)) + sum(sin.(v) .+ 1)))),
            "zeros, ntuple"      => () -> r6(sum(zeros(SVector{4,Float64})) + length(SVector{5,Float64}(ntuple(i -> i * opaque(1.0), 5))) + sum(SVector{5,Float64}(ntuple(i -> i * opaque(1.0), 5)))),
            "push, pop"          => @opaque(() -> (w = push(SVector(1, 2, 3), 4); length(w) * 10 + pop(w)[end])),
            "vcat, hcat"         => @opaque(() -> (a = SVector(1.0, 2.0); b = SVector(3.0, 4.0); r6(sum([a; b]) + sum(hcat(a, b))))),
            "sort"               => @opaque(() -> (v = SVector(3.0, 1.0, 2.0); r6(sort(v)[1] * 10 + sort(v)[3]))),
            "@SVector"           => () -> (v = @SVector [opaque(1.0), 2.0, 3.0]; r6(sum(v))),
            "in a Vector"        => @opaque(() -> (vs = [SVector(1.0, 2.0), SVector(3.0, 4.0)]; r6(sum(sum, vs)))),
            "as a Dict key"      => @opaque(() -> (d = Dict(SVector(1, 2) => 10, SVector(3, 4) => 20); d[SVector(3, 4)])),
            "MVector"            => @opaque(() -> (v = MVector{3,Float64}(1.0, 2, 3); v[2] = 7; r6(sum(v)))),
            "a FieldVector"      => @opaque(() -> (p = Pt3(1.0, 2.0, 3.0); r6(sum(p) + norm(p)))),
        ])
    end

    @testset "Matrices and linear algebra" begin
        check_cases([
            "product, determinant" => @opaque(() -> (A = SMatrix{3,3}(1.0, 2, 3, 4, 5, 6, 7, 8, 10); r6(sum(A * A) + det(A)))),
            "inverse"            => @opaque(() -> r6(sum(inv(SMatrix{3,3}(1.0, 2, 3, 4, 5, 6, 7, 8, 10))))),
            "solve"              => @opaque(() -> r6(sum(SMatrix{3,3}(1.0, 2, 3, 4, 5, 6, 7, 8, 10) \ SVector(1.0, 2.0, 3.0)))),
            "eigenvalues"        => @opaque(() -> r6(sum(eigvals(Symmetric(SMatrix{2,2}(2.0, 1, 1, 2)))))),
            "transpose"          => @opaque(() -> (A = SMatrix{2,3}(1.0, 2, 3, 4, 5, 6); r6(sum(A' * A)))),
            "a rotation"         => @opaque(() -> (θ = 0.3; R = SMatrix{2,2}(cos(θ), sin(θ), -sin(θ), cos(θ)); v = R * SVector(1.0, 0.0); r6(v[1] + 2v[2]))),
            "@SMatrix"           => () -> r6(sum(@SMatrix [opaque(1.0) 2.0; 3.0 4.0])),
            "SArray of 3 dimensions" => @opaque(() -> (A = SArray{Tuple{2,2,2}}(ntuple(i -> Float64(i), 8)); r6(sum(A) + A[2, 1, 2]))),
            "MMatrix"            => @opaque(() -> (A = zeros(MMatrix{2,2,Float64}); A[1, 2] = 3.0; r6(sum(A)))),
            "qr"                 => @opaque(() -> r6(sum(abs, qr(SMatrix{3,3}(1.0, 2, 3, 4, 5, 6, 7, 8, 10)).R))),
            "svdvals"            => @opaque(() -> r6(sum(svdvals(SMatrix{3,3}(1.0, 2, 3, 4, 5, 6, 7, 8, 10))))),
            "cholesky"           => @opaque(() -> r6(sum(cholesky(Symmetric(SMatrix{2,2}(4.0, 2, 2, 3))).L))),
            "lu"                 => @opaque(() -> r6(sum(lu(SMatrix{3,3}(1.0, 2, 3, 4, 5, 6, 7, 8, 10)).U))),
        ])
    end
end
