# Parts of the language and of the standard library that were found, by a survey, not to compile, and now do: each program is compared with Julia.

function check_all(cases)
    @testset "$name" for (name, f) in cases
        status, detail = static_status(f)
        @test (status, first(replace(string(detail), '\n' => ' '), 300)) == (:ok, "")
    end
end

cov_adder(k) = x -> x + k
const COV_ADD3 = cov_adder(3)
const COV_ANYF = Any[cov_adder(5), sin]
const COV_DICTF = Dict{String,Function}("a" => cov_adder(1), "b" => cos)

function threads_sum(s)
    Threads.@threads for i in 1:10
        Threads.atomic_add!(s, i)
    end
    return s[]
end

@testset "Coverage" begin
    any_value(x) = Base.inferencebarrier(x)

    @testset "Base" begin
        check_all([
            "string(1, x::Any)"       => () -> (println(string(1, any_value(5), 2.5, any_value("q"), :s, 'c')); 0),
            "interpolating an Any"    => () -> (x = any_value(7); println("x=$(1 + 1) y=$(x) z=$(any_value("w"))"); 0),
            "string of a few ints"    => () -> (println(string(1, 2, 3)); 0),
            "splice! an element"      => () -> (v = [1, 2, 3, 4]; r = splice!(v, 2); println(r, v); r2 = splice!(v, 1, [7, 8, 9]); println(r2, v); 0),
            "splice! a range"         => () -> (v = [1, 2, 3, 4, 5]; r = splice!(v, 2:3, [9, 9, 9]); println(r, v); r = splice!(v, 2:4); println(r, v); r = splice!(v, 2:1, 5); println(r, v); 0),
            "splice! out of range"    => () -> (v = [1, 2]; try; splice!(v, 5); catch e; println(e isa BoundsError); end; 0),
            "sleep"                   => () -> (t = time(); sleep(0.05); println(time() - t >= 0.04); 0),
            "sleep with a bad time"   => () -> (try; sleep(-1); catch e; println(e isa ArgumentError); end; 0),
            "iterating a mixed tuple" => () -> (s = 0; for x in (1, 2.5, 3); s += x; end; println(s); 0),
            "summary of an array"     => () -> (println(summary([1, 2])); println(summary([1.0 2.0])); 0),
            "a type to an IOBuffer"   => () -> (io = IOBuffer(); print(io, Vector{Int}); println(String(take!(io))); 0),
        ])
    end

    @testset "Dates" begin
        const_format = dateformat"dd/mm/yyyy"
        check_all([
            "construct and fields"    => () -> (d = Date(2020, 3, 15); year(d) * 10000 + month(d) * 100 + day(d)),
            "arithmetic"              => () -> (d = Date(2020, 2, 28) + Day(2); month(d) * 100 + day(d)),
            "difference"              => () -> Dates.value(Date(2021, 1, 1) - Date(2020, 1, 1)),
            "calendar functions"      => () -> dayofweek(Date(2024, 2, 29)) + isleapyear(2024) + dayofyear(Date(2024, 12, 31)),
            "DateTime"                => () -> (t = DateTime(2020, 1, 2, 3, 4, 5); hour(t) * 10000 + minute(t) * 100 + second(t)),
            "periods"                 => () -> Dates.value(Month(3) + Month(4)) + Dates.value(Day(5) * 2),
            "show"                    => () -> (println(Date(2020, 3, 15)); println(DateTime(2020, 1, 2, 3, 4, 5)); println(Time(10, 20, 30)); 0),
            "ranges"                  => () -> length(Date(2020, 1, 1):Day(1):Date(2020, 1, 31)),
            "names"                   => () -> (println(monthname(Date(2020, 3, 1)), dayname(Date(2020, 3, 1))); 0),
            "parse an ISO date"       => () -> (d = Date(any_value("2021-12-25")); year(d) + day(d)),
            "parse a date time"       => () -> (d = DateTime(any_value("2021-12-25T10:20:30")); hour(d) + minute(d)),
            "tryparse"                => () -> (d = tryparse(Date, any_value("2021-12-25")); d === nothing ? 0 : year(d)),
            "parse with a format"     => () -> (d = Date(any_value("25/12/2021"), const_format); year(d) * 10000 + month(d) * 100 + day(d)),
            "format with a format"    => () -> (println(Dates.format(Date(2021, 12, 25), const_format)); 0),
            "now and today"           => () -> (year(today()) > 2000) + (year(now()) > 2000),
            "unix2datetime"           => () -> year(unix2datetime(1.6e9)),
        ])
    end

    @testset "SparseArrays" begin
        csc() = SparseMatrixCSC(2, 2, [1, 2, 3], [1, 2], [1.0, 2.0])
        check_all([
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

    @testset "Closures and functions that are not known" begin
        mutable struct Holder; f::Function; end
        make_adder(k) = x -> x + k
        make_counter() = (n = 0; () -> (n += 1))
        apply_all(fs, x) = map(f -> f(x), fs)
        kw(x; k = 2) = x * k
        any_function = any_value
        FS = Function[sin, cos, x -> 2x]
        check_all([
            "a closure that captures"      => () -> make_adder(3)(4),
            "a variable that is boxed"     => () -> (c = make_counter(); c(); c(); c()),
            "a variable that is changed"   => () -> (x = 1; f = () -> x; x = 2; f()),
            "closures made in a loop"      => () -> (fs = [x -> x + i for i in 1:3]; sum(f(10) for f in fs)),
            "a vector of two closures"     => () -> (fs = [x -> x + 1, x -> x * 2]; fs[1](fs[2](5))),
            "a Vector{Function}"           => () -> (s = 0.0; for f in Function[sin, cos, x -> 2x]; s += f(1.0); end; round(Int, 1000s)),
            "a Vector{Function} in a local" => () -> (s = 0.0; for f in FS; s += f(1.0); end; round(Int, 1000s)),
            "a function of type Any"       => () -> any_function(sin)(1.0) > 0,
            "a closure of type Any"        => () -> any_function(x -> x + 1)(2),
            "a Dict of functions"          => () -> (d = Dict("a" => sin, "b" => cos); d["b"](0.0) + d["a"](0.0)),
            "a Ref{Function}"              => () -> (r = Ref{Function}(sin); r[] = cos; r[](0.0)),
            "a field of type Function"     => () -> (h = Holder(sin); h.f(0.0) + (h.f = cos; h.f(0.0))),
            "a closure that calls itself"  => () -> (fib = nothing; fib = n -> n < 2 ? n : fib(n - 1) + fib(n - 2); fib(10)),
            "a local function with keywords, in a closure" => () -> (f(x; k = 2) = x * k; g = () -> f(3; k = 4); g()),
            "a constant closure with state" => () -> COV_ADD3(4),
            "a constant Any[closure, sin]" => () -> COV_ANYF[1](1) + COV_ANYF[2](0.0),
            "a constant Dict of closures"  => () -> COV_DICTF["a"](1) + COV_DICTF["b"](0.0),
            "functions that are composed"  => () -> (fs = (x -> x + 1, x -> x * 3); foldl((a, f) -> f(a), fs; init = 2)),
            "a function and Base.Fix2"     => () -> (fs = Function[Base.Fix2(+, 1), Base.Fix1(*, 3)]; fs[1](1) + fs[2](2)),
            "a function that is not called" => () -> (fs = Function[sin, x -> 2x]; length(fs)),
        ])
    end

    @testset "Schur" begin
        r6(x) = round(Int, 1e6 * x)
        A = [4.0 1.0; 2.0 3.0]
        R = [0.0 -1.0; 1.0 0.0] # (complex eigenvalues)
        check_all([
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

    @testset "Broadcasts and products of complex numbers and rationals" begin
        r6(x) = round(Int, 1e6 * x)
        Z = [0.6 0.8; -0.8 0.6]
        C = ComplexF64[4 1im; 0 3]
        Q = Rational{Int}[1 2; 3 4]
        check_all([
            "abs. of a complex matrix"   => () -> r6(sum(abs.(C))),
            "real and imag"              => () -> r6(sum(real(C)) + sum(imag(C))),
            "complex .* complex"         => () -> r6(sum(abs, C .* C)),
            "complex .+ 1"               => () -> r6(sum(abs, C .+ 1)),
            "conj."                      => () -> r6(sum(abs, imag.(conj.(C)))),
            "a real by a complex matrix" => () -> r6(sum(abs, Z * C)),
            "a complex by a real matrix" => () -> r6(sum(abs, C * Z)),
            "a rational matrix"          => () -> (R = Q .+ 1; Int(sum(numerator, R)) * 100 + Int(sum(denominator, R))),
            "a rational product"         => () -> (R = Q * Q; Int(sum(numerator, R)) * 100 + Int(sum(denominator, R))),
            "complex vectors"            => () -> r6(sum(abs.(ComplexF64[1, 2im] .* 2))),
        ])
    end

    @testset "SparseArrays factorizations" begin
        r6(x) = round(Int, 1e6 * x)
        poisson(n) = (T = spdiagm(-1 => fill(-1.0, n - 1), 0 => fill(2.0, n), 1 => fill(-1.0, n - 1)); kron(sparse(I, n, n), T) + kron(T, sparse(I, n, n)))
        check_all([
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

    @testset "Standard libraries" begin
        dir() = (d = joinpath(tempdir(), string("static_cov_", Libc.getpid())); isdir(d) && rm(d; recursive = true); mkdir(d); d)
        check_all([
            "Base64 encode"            => () -> (println(base64encode(any_value("hello world")), base64encode(UInt8[]), base64encode("a"), base64encode("ab")); 0),
            "Base64 decode"            => () -> (println(String(base64decode(any_value("aGVsbG8gd29ybGQ=")))); println(String(base64decode(any_value("aGVsbG8")))); 0),
            "Base64 round trip"        => () -> (b = Vector{UInt8}(1:200); Int(base64decode(base64encode(b)) == b)),
            "CRC32c"                   => () -> Int(crc32c(any_value("hello"))) + Int(crc32c(UInt8[1, 2, 3, 4, 5], 0x12345678)),
            "NullLogger"               => () -> (with_logger(NullLogger()) do; @warn "hidden"; end; 0),
            "IdSet"                    => () -> (s = Base.IdSet{Any}(); a = [1]; b = [1]; push!(s, a); push!(s, a); push!(s, b); pop!(s, a); length(s) * 10 + Int(b in s) + Int(a in s) * 100),
            "IdSet of many"            => () -> (s = Base.IdSet{Any}(); xs = [[i] for i in 1:50]; for x in xs; push!(s, x); end; for x in xs[1:10]; delete!(s, x); end; length(s) + count(x -> x in s, xs)),
            "paths"                    => () -> (println(basename("/a/b.txt"), dirname("/a/b.txt"), splitext("b.txt"), joinpath("a", "b"), normpath("/a/../b")); 0),
            "mkdir, isdir, rm"         => () -> (d = dir(); r = Int(isdir(d)); rm(d); r + Int(isdir(d)) + Int(ispath(d))),
            "files: isfile, filesize"  => () -> (d = dir(); p = joinpath(d, "f"); write(p, "hello"); r = Int(isfile(p)) + Int(ispath(p)) + filesize(p) + Int(isdir(p)); rm(d; recursive = true); r),
            "stat"                     => () -> (d = dir(); p = joinpath(d, "f"); write(p, "abc"); s = stat(p); r = Int(s.size) + Int(mtime(p) > 0) + Int(filemode(p) & 0o400 != 0); rm(d; recursive = true); r),
            "readdir"                  => () -> (d = dir(); write(joinpath(d, "b.txt"), "y"); write(joinpath(d, "a.txt"), "x"); mkdir(joinpath(d, "sub")); n = readdir(d); println(n); println(readdir(d; join = true) == joinpath.(d, n)); rm(d; recursive = true); length(n)),
            "cp and mv"                => () -> (d = dir(); p = joinpath(d, "f"); write(p, "abc"); cp(p, p * "2"); mv(p * "2", p * "3"); r = length(read(p * "3", String)) + Int(!ispath(p * "2")); rm(d; recursive = true); r),
            "cp of a directory"        => () -> (d = dir(); mkdir(joinpath(d, "s")); write(joinpath(d, "s", "x"), "hi"); cp(joinpath(d, "s"), joinpath(d, "t")); r = length(read(joinpath(d, "t", "x"), String)); rm(d; recursive = true); r),
            "rm of what is not there"  => () -> (d = dir(); rm(joinpath(d, "nothing"); force = true); r = (try; rm(joinpath(d, "nothing")); 0; catch e; 1; end); rm(d); r),
            "mkdir of one that exists" => () -> (d = dir(); r = (try; mkdir(d); 0; catch e; 1; end); rm(d); r),
            "pwd and cd"               => () -> (d = realpath(dir()); old = pwd(); cd(d); r = Int(realpath(pwd()) == d); cd(old); rm(d); r + Int(pwd() == old)),
            "temporary files"          => () -> ((p, io) = mktemp(); close(io); r = Int(isfile(p)); rm(p); q = tempname(); r + Int(!ispath(q)) + Int(isdir(tempdir()))),
            "mktempdir with a function" => () -> (path = mktempdir(d -> (write(joinpath(d, "x"), "1"); d)); Int(!ispath(path))),
            "environment"              => () -> (ENV["STATIC_COVERAGE_X"] = "5"; r = parse(Int, ENV["STATIC_COVERAGE_X"]) + Int(haskey(ENV, "STATIC_COVERAGE_X")); delete!(ENV, "STATIC_COVERAGE_X"); r + Int(haskey(ENV, "STATIC_COVERAGE_X"))),
            "process id and homedir"   => () -> Int(Libc.getpid() > 0) + Int(length(homedir()) > 0),
            "@threads"                 => () -> (s = Threads.Atomic{Int}(0); threads_sum(s)),
        ])
    end
end
