# Numbers: arithmetic and the functions of the math library, complex numbers and rationals (broadcasts and products of arrays of them), and reductions that Julia vectorizes.

@testset "Arithmetic and functions" begin
    check_cases([
    "arithmetic" => @opaque(() -> 3 * 4 + 1),
    "float math" => @opaque(() -> sin(1.0) + sqrt(2.0)),
    ])
end

@testset "Complex numbers and rationals: broadcasts and products" begin
    Z = [0.6 0.8; -0.8 0.6]
    C = ComplexF64[4 1im; 0 3]
    Q = Rational{Int}[1 2; 3 4]
    check_cases([
        "abs. of a complex matrix" => @opaque(() -> r6(sum(abs.(C)))),
        "real and imag" => @opaque(() -> r6(sum(real(C)) + sum(imag(C)))),
        "complex .* complex" => @opaque(() -> r6(sum(abs, C .* C))),
        "complex .+ 1" => @opaque(() -> r6(sum(abs, C .+ 1))),
        "conj." => @opaque(() -> r6(sum(abs, imag.(conj.(C))))),
        "a real by a complex matrix" => () -> r6(sum(abs, Z * C)),
        "a complex by a real matrix" => () -> r6(sum(abs, C * Z)),
        "a rational matrix" => @opaque(() -> (R = Q .+ 1; Int(sum(numerator, R)) * 100 + Int(sum(denominator, R)))),
        "a rational product" => @opaque(() -> (R = Q * Q; Int(sum(numerator, R)) * 100 + Int(sum(denominator, R)))),
        "complex vectors" => @opaque(() -> r6(sum(abs.(ComplexF64[1, 2im] .* 2)))),
    ])
end


# `@simd` reductions are reassociated by Julia (several partial sums, with the vectorizer): without it they are a plain loop, and the results
# differ in the last digits (and are less accurate: `sum(fill(0.1f0, 1000))` is 99.99905 for a plain loop, and 99.99994 for Julia)
simd_sum32() = (s = 0f0; v = fill(0.1f0, 1000); @simd for x in v; s += x; end; s)
simd_sum64() = (s = 0.0; v = fill(0.1, 1000); @simd for x in v; s += x; end; s)
base_sum32() = sum(fill(0.1f0, 1000))
base_sum64() = sum(fill(0.1, 1000))
base_dot() = (x = fill(0.1f0, 999); y = fill(0.3f0, 999); LinearAlgebra.dot(x, y))
base_mean() = (using_Statistics_mean(fill(0.1f0, 1000)))
using_Statistics_mean(v) = sum(v) / length(v)
@testset "Reductions that are vectorized (`@simd`, `sum`, `dot`)" begin
    for f in (simd_sum32, simd_sum64, base_sum32, base_sum64, base_dot, base_mean)
        @test static_status(f)[1] == :ok
    end
end
