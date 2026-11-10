# LinearAlgebra: the library that backs BLAS and LAPACK (libblastrampoline: the binary needs it, and the library that backs it, when it is run), products and factorizations, and the matrix functions of the Schur factorization.

# BLAS through libblastrampoline: the program uses the library that was forwarded to when it was compiled
blas_work() = (a = [sin(i + 2j) for i in 1:30, j in 1:30]; b = [cos(i - j) for i in 1:30, j in 1:30];
               x = (a + 10I) \ b[:, 1];
               round(Int, 1000 * (sum(a * b) + sum(x) + det(a[1:3, 1:3]) + sum(eigvals(Symmetric(a[1:4, 1:4]))) + dot(b[:, 1], b[:, 2]))))

@testset "BLAS: the library that backs it is the one forwarded to when compiling" begin
    @testset "libblastrampoline, loaded when needed" begin
        @test static_result(blas_work) == blas_work()
    end
    # a program that does not use BLAS does not load it
    @testset "not loaded when not used" begin
        exe_dir = mktempdir()
        main = StaticCompilerOverrides.make_main(() -> 1 + 1)
        exe = compile_executable(main, (Int, Ptr{Ptr{UInt8}}), exe_dir, string(nameof(main)))
        @test !occursin("blastrampoline", String(read(exe)))
    end
    # the library that backs it is what was set when compiling: Accelerate, where it is there (it forwards some of BLAS
    # and LAPACK, so the libraries are used together, as in Julia)
    @testset "Accelerate" begin
        if Sys.isapple() && Base.find_package("AppleAccelerate") !== nothing
            Core.eval(Main, :(using AppleAccelerate))
            before = BLAS.get_config()
            try
                Base.invokelatest(() -> Main.AppleAccelerate.load_accelerate()) # (the module was loaded just now: a newer world)
                @test any(l -> occursin("Accelerate", l.libname), BLAS.get_config().loaded_libs)
                @test static_result(blas_work) == blas_work()
            finally
                path = first(l.libname for l in before.loaded_libs)
                BLAS.lbt_forward(path; clear = true)
            end
        else
            @info "Skipping the Accelerate test: AppleAccelerate is not installed"
        end
    end
end

@testset "BLAS: products and norms" begin
    check_cases([
    "dot/norm"              => () -> round(Int, 100 * (dot([1.0, 2.0], [3.0, 4.0]) + norm([3.0, 4.0]))),
    "matmul 100x100"        => () -> (a = [sin(i + 2j) for i in 1:100, j in 1:100]; b = [cos(i - j) for i in 1:100, j in 1:100]; round(Int, 1000 * sum(a * b))),
    "mul! Float32"          => () -> (a = Float32[1 2; 3 4]; c = zeros(Float32, 2, 2); mul!(c, a, a); Int(sum(c))),
    "matmul ComplexF64"     => () -> (a = [1.0+1im 2.0; 0.0 1.0-1im]; Int(real(sum(a * a)))),
    "matvec"                => () -> (m = [1.0 2.0; 3.0 4.0]; Int(sum(m * [1.0, 1.0]))),
    ])
end

@testset "LAPACK: solving, factorizations and eigenvalues" begin
    check_cases([
    "det/inv"               => () -> (m = [2.0 1.0; 1.0 3.0]; round(Int, 100 * (det(m) + sum(inv(m))))),
    "solve with \\"          => () -> (m = [2.0 1.0; 1.0 3.0]; round(Int, 100 * sum(m \ [1.0, 2.0]))),
    "lu"                    => () -> round(Int, 100 * det(lu([2.0 1.0; 1.0 3.0]))),
    "cholesky"              => () -> round(Int, 100 * sum(cholesky([4.0 2.0; 2.0 3.0]).L)),
    "qr"                    => () -> round(Int, 100 * abs(det(qr([1.0 2.0; 3.0 4.0]).R))),
    "svdvals"               => () -> round(Int, 100 * sum(svdvals([1.0 2.0; 3.0 4.0]))),
    "eigvals Symmetric"     => () -> round(Int, 100 * sum(eigvals(Symmetric([2.0 1.0; 1.0 2.0])))),
    ])
end

@testset "Schur factorizations, and the matrix functions that use them (sqrt, log, powers)" begin
    A = [4.0 1.0; 2.0 3.0]
    R = [0.0 -1.0; 1.0 0.0] # (complex eigenvalues)
    check_cases([
        "schur, real eigenvalues"    => () -> (F = schur(A); r6(sum(F.T) + sum(F.Z) + sum(real(F.values)))),
        "schur, complex eigenvalues" => () -> (F = schur(R); r6(sum(abs, F.T) + sum(abs, F.Z) + sum(abs, imag(F.values)))),
        "schur of a Float32"         => () -> r6(sum(schur(Float32[4 1; 2 3]).T)),
        "schur of a complex matrix"  => () -> r6(sum(abs, schur(ComplexF64[4 1im; 2 3]).T)),
        "ordschur"                   => () -> (F = schur([1.0 2 0; 0 3 1; 1 0 2]); r6(sum(abs, ordschur(F, [false, true, false]).T))),
        "sqrt, nonsymmetric"         => () -> r6(sum(sqrt(A))),
        "sqrt, 3 by 3"               => () -> r6(sum(sqrt([1.0 2 0; 0 3 1; 1 0 2]))),
        "sqrt, negative eigenvalue"  => () -> r6(sum(abs, sqrt([1.0 2; 3 -4]))),
        "sqrt, symmetric"            => () -> r6(sum(sqrt([2.0 1; 1 2]))),
        "log, nonsymmetric"          => () -> r6(sum(log(A))),
        "log, 3 by 3"                => () -> r6(sum(log([1.0 2 0; 0 3 1; 1 0 2]))),
        "matrix power"               => () -> r6(sum(A^0.5) + sum(A^2.5)),
        "sqrt(A)^2 == A"             => () -> r6(sum(abs, sqrt(A)^2 - A)),
        "exp(log(A)) == A"           => () -> r6(sum(abs, exp(log(A)) - A)),
    ])
end
