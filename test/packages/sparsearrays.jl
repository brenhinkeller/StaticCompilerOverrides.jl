# SparseArrays: the sparse types, and the factorizations (`\`, `lu`, `cholesky`, `ldlt`, `qr`, `det`, ...: SuiteSparse's libraries UMFPACK, CHOLMOD and SPQR, called as any library is, with the setup that the extension for `SparseArrays` does), compared with Julia's.

@testset "SparseArrays" begin
    csc() = SparseMatrixCSC(2, 2, [1, 2, 3], [1, 2], [1.0, 2.0])
    check_cases([
        "constructors"            => () -> nnz(sparse([1, 2], [1, 2], [1.0, 2.0])) + nnz(spzeros(3, 3)) + nnz(csc()),
        "getindex and setindex"   => () -> (A = spzeros(3, 3); A[2, 2] = 5.0; Int(A[2, 2]) + nnz(A) + Int(csc()[2, 2])),
        "matrix-vector product"   => () -> Int(sum(csc() * [1.0, 1.0])),
        "sums, nonzeros, findnz"  => () -> (A = sparse([1, 3], [1, 2], [1.0, 2.0]); (r, c, v) = findnz(A); Int(sum(A)) + Int(sum(nonzeros(A))) + sum(r) + sum(c)),
        "products and transpose"  => () -> (A = sparse([1.0 2; 0 1]); Int(sum(A * A)) + Int(sum(A' * A)) + nnz(kron(A, A))),
        "identity and diagonals"  => () -> (A = sparse(I, 3, 3); nnz(A) + Int(tr(A)) + nnz(spdiagm(0 => [1.0, 2, 3]))),
        "sparse vectors"          => () -> (v = sparsevec([1, 4], [1.0, 2.0], 5); Int(sum(v)) + nnz(v)),
        "show"                    => () -> (println(sparse([1, 2], [1, 2], [1.0, 2.0])); 0),
    ])
end

@testset "SparseArrays factorizations" begin
    poisson(n) = (T = spdiagm(-1 => fill(-1.0, n - 1), 0 => fill(2.0, n), 1 => fill(-1.0, n - 1)); kron(sparse(I, n, n), T) + kron(T, sparse(I, n, n)))
    check_cases([
        "\\ of a tridiagonal"      => () -> (A = spdiagm(-1 => [1.0, 1], 0 => [4.0, 4, 4], 1 => [1.0, 1]); r6(sum(A \ [1.0, 2, 3]))),
        "lu and its solve"        => () -> (A = sparse([4.0 1; 1 3.0]); F = lu(A); r6(sum(F \ [1.0, 2.0]))),
        "determinant of the lu"   => () -> (A = sparse([4.0 1 0; 1 3.0 1; 0 1 5.0]); r6(det(lu(A)))),
        "cholesky"                => () -> (A = sparse([4.0 1; 1 3.0]); F = cholesky(Symmetric(A)); r6(sum(F \ [1.0, 2.0])) + r6(logdet(F))),
        "ldlt"                    => () -> (A = sparse([4.0 1; 1 3.0]); r6(sum(ldlt(Symmetric(A)) \ [1.0, 2.0]))),
        "a 400-unknown system"    => () -> r6(sum(poisson(20) \ ones(400))),
        "cholesky of 900"         => () -> r6(sum(cholesky(Symmetric(poisson(30))) \ ones(900))),
        "a matrix of right sides" => () -> (A = sparse([4.0 1; 1 3.0]); r6(sum(A \ [1.0 0; 0 1.0]))),
        "a random system"         => () -> (A = sprand(MersenneTwister(1), 200, 200, 0.05) + 10I; r6(sum(A \ ones(200)))),
        "least squares (qr)"      => () -> (A = sparse([1.0 0; 0 1; 1 1]); r6(sum(A \ [1.0, 2, 3]))),
        "not positive definite"   => () -> (A = sparse([1.0 2; 2 1.0]); try; cholesky(Symmetric(A)); 0; catch e; e isa PosDefException ? 1 : 2; end),
        "singular"                => () -> (A = sparse([1.0 2; 2 4.0]); try; lu(A) \ [1.0, 2]; 0; catch e; e isa SingularException ? 1 : 2; end),
        "factorize"               => () -> (A = sparse([4.0 1; 1 3.0]); r6(sum(factorize(A) \ [1.0, 2.0]))),
        "many factorizations"     => () -> (s = 0.0; for i in 1:300; A = sparse([4.0 + i 1; 1 3.0]); s += sum(lu(A) \ [1.0, 2.0]); end; r6(s)), # (the finalizers free them)
        "complex"                 => () -> (A = sparse([4.0 + 1im 1; 1 3.0]); r6(real(sum(A \ [1.0 + 0im, 2])))),
    ])
end

