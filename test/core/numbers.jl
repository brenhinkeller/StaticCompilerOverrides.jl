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

# Edge cases where a compiled program could differ from Julia without saying so: the order of a reduction, NaN and signed zero, rounding of halves, the sign of `mod` and `rem`, shifts by
# more than the width, overflow, and how floats are written. (Each is compared with Julia: what it writes, and its result.)
fastmath_sum(x) = (s = 0.0; (@fastmath for v in x; s += v * v; end); s)
simd_sin_sum(n) = (s = 0.0f0; (@simd for i in 1:n; s += sin(Float32(i)); end); s)
@testset "Numeric edge cases" begin
    check_cases([
        "sum of Float32 and Float16"   => () -> (println(sum(fill(opaque(0.1f0), 1000)), " ", sum(fill(opaque(Float16(0.1)), 1000)), " ", cumsum(fill(opaque(0.1f0), 100))[end]); 0),
        "dot of Float32"               => () -> (println(dot(fill(opaque(0.1f0), 1003), fill(opaque(0.3f0), 1003))); 0),
        # (`prod` of a vector is a reduction with `@simd`, which may add up in any order: the program is optimized again after it is linked, and can do so differently from Julia, by a unit in the last place)
        "mean, var, std, prod"         => () -> (x = [opaque(0.1) * i^2 for i in 1:1001]; println(mean(x), " ", var(x), " ", std(x), " ", round(prod(fill(opaque(1.001), 1000)); sigdigits = 12)); 0),
        "@simd and @fastmath loops"    => () -> (println(simd_sin_sum(opaque(1000)), " ", fastmath_sum(fill(opaque(0.1), 1000))); 0),
        "NaN in minimum, findmax, sort" => () -> (x = [1.0, NaN, opaque(0.5)]; println(minimum(x), maximum(x), extrema(x), findmax(x), findmin(x)); y = [opaque(1.0), NaN, -0.0, 0.0, -Inf, 2.0]; println(sort(y), sortperm(y)); 0),
        "rounding of halves"           => () -> (println(round(opaque(2.5)), round(opaque(-0.5)), round(opaque(3.5)), round(Int, opaque(2.5)), trunc(opaque(-1.7)), floor(Int, opaque(-1.1)), ceil(opaque(-0.2))); 0),
        "mod, rem, fld, cld of negatives" => () -> (println(mod(opaque(-7), 3), rem(opaque(-7), 3), fld(opaque(-7), 3), cld(opaque(-7), 3), divrem(opaque(-7), 3), mod(opaque(-7.5), 2.0), rem(opaque(5.5), -2.0)); 0),
        "shifts by more than the width" => () -> (println(opaque(1) << 64, opaque(1) << 63, opaque(-8) >> 70, opaque(-8) >>> 1, opaque(1) << -1, UInt8(opaque(200)) << 1); 0),
        "overflow wraps"               => () -> (println(typemax(Int) + opaque(1), abs(typemin(Int) + opaque(0)), -(typemin(Int) + opaque(0)), Int8(100) * opaque(Int8(2)), UInt(0) - opaque(UInt(1))); 0),
        "division by zero, conversions" => () -> (println(opaque(1.0) / 0, -opaque(1.0) / 0, 0.0 / opaque(0.0), Float32(opaque(16777217)), Float64(typemax(Int) + opaque(0)), unsafe_trunc(Int, opaque(1e30))); 0),
        "floats as text"               => () -> (println(opaque(0.1f0), " ", opaque(1e23), " ", opaque(5e-324), " ", opaque(123456789.0f0), " ", opaque(1e-7), " ", Float16(opaque(0.1))); 0),
        "parsing floats"               => () -> (println(parse(Float64, "0.1"), parse(Float32, "1e-45"), tryparse(Float64, "1_0"), tryparse(Float64, "1.7976931348623157e309"), parse(Float64, "  3 ")); 0),
        "special functions"            => () -> (println(opaque(2.0)^0.5, opaque(10)^opaque(18), exp(opaque(1.0)), log1p(opaque(1e-10)), cbrt(opaque(27.0)), hypot(opaque(3.0), 4.0), atan(opaque(1.0), -1.0)); 0),
        "bit operations"               => () -> (println(count_ones(opaque(255)), leading_zeros(opaque(1)), trailing_zeros(opaque(8)), bitreverse(UInt8(opaque(1))), bswap(UInt32(opaque(1))), ~opaque(0)); 0),
    ])
end

# `fma` (and what asks for it: `log`, `^`, `muladd`) is made with the instruction of the processor, as Julia does: it is not made by software, which is several times slower
fma_of(x::Float64, y::Float64, z::Float64) = fma(x, y, z)
@testset "fma is an instruction" begin
    llvm = sprint(io -> static_code_llvm(fma_of, Tuple{Float64,Float64,Float64}; io, llvm_postprocess = m -> nothing))
    @test occursin("llvm.fma", llvm)
    @test !occursin("fma_emulated", llvm)
    @test static_status(() -> fma(opaque(2.0), 3.0, 1.0) + log(opaque(2.0)))[1] == :ok
end
