# Parts of the language and of the standard library that were found, by a survey, not to compile, and now do: each program is compared with Julia.

function check_all(cases)
    @testset "$name" for (name, f) in cases
        status, detail = static_status(f)
        @test (status, first(replace(string(detail), '\n' => ' '), 300)) == (:ok, "")
    end
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
end
