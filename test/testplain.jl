# `text/plain` (what `display` writes, and `show(io, MIME"text/plain"(), x)`), and the properties of the context (`IOContext(io, :compact => true)`, `:limit`, `:displaysize`), which
# are Base's own code running on the streams of `context.jl` (the properties are in the type of the stream, so they are known when compiling).
# What is written is compared with what Julia writes.

const PL_TP = MIME"text/plain"()
struct PlPoint; x::Int; y::Float64; end
pl_text(x) = (println(sprint(show, PL_TP, x)); 0)
pl_nl() = print(STDOUT, "\n")

pl_matrix_int() = pl_text([1 2; 3 4])
pl_matrix_float() = pl_text([1.5 2.0; 3.0 4.25])
pl_matrix_compact_floats() = pl_text([0.1+0.2 1/3; 2/3 1.0])      # (a matrix is shown with `:compact`: `0.3`)
pl_matrix_float32() = pl_text(Float32[1.5 2.0; 3.0 4.25])
pl_matrix_string() = pl_text(["a" "bc"; "d" "e"])
pl_matrix_bool() = pl_text([true false; false true])
pl_matrix_any() = pl_text(Any[1 "a"; 2.5 :s])
pl_matrix_complex() = pl_text([1+2im 3-1im; 0im 1im])
pl_matrix_complex_float() = pl_text([1.0e-5+2.5e10im 3.0-1.0e-3im; 1.5+2.5im 0.0im])
pl_matrix_rational() = pl_text([1//2 3//4; 1//1 2//3])
pl_matrix_wide() = pl_text([1 1000000; -5 12345])
pl_matrix_exponents() = pl_text([-1.5e-10 2.0; 1e20 -0.25])
pl_column() = pl_text(reshape([1.5, 22.25, 3.0], 3, 1))
pl_empty() = (pl_text(zeros(0, 3)); pl_text(Int[]); pl_text(Matrix{Float64}(undef, 0, 0)); 0)
pl_3d() = pl_text(reshape(1:8, 2, 2, 2))
pl_vector_int() = pl_text([1, 2, 3])
pl_vector_float() = pl_text([1.5, 2.0, 0.1 + 0.2])
pl_vector_string() = pl_text(["a", "bc"])
pl_vector_any() = pl_text(Any[1, "a", 2.5])
pl_range() = (pl_text(1:5); pl_text(0.5:0.5:2.0); 0)
pl_dict() = (pl_text(Dict(:a => 1, :b => 2)); pl_text(Dict("x" => 1.5)); 0)
pl_set() = pl_text(Set([1, 2, 3]))
pl_scalars() = (pl_text(3.5); pl_text("str"); pl_text(nothing); pl_text((1, "a")); pl_text(:a => 1); pl_text('c'); pl_text(true); 0)
pl_struct() = pl_text(PlPoint(1, 2.5))
pl_wrappers() = (pl_text([1 2; 3 4]'); pl_text(view([1 2 3; 4 5 6], 1:2, 2:3)); pl_text(reshape(1:6, 2, 3)); 0)
pl_chars() = (pl_text('a'); pl_text('é'); pl_text('1'); pl_text(' '); pl_text('日'); pl_text('\n'); 0)
pl_sprint_any() = (x = Base.inferencebarrier(1)::Any; println(sprint(show, x)); y = Base.inferencebarrier("s")::Any; println(sprint(show, y)); 0)

# the properties of a context, written as Julia does (to the standard output of libc, with the same stream in Julia and in the program)
pl_ctx_compact() = (show(IOContext(STDOUT, :compact => true), 0.1 + 0.2); pl_nl(); show(IOContext(STDOUT, :compact => true), [0.1 + 0.2, 1/3]); pl_nl();
                    show(IOContext(STDOUT, :compact => true), [0.1+0.2 1/3; 2/3 1.0]); pl_nl(); show(IOContext(STDOUT, :compact => true), 0.1 + 0.2im); pl_nl(); 0)
pl_ctx_limit_vector() = (show(IOContext(STDOUT, :limit => true), collect(1:30)); pl_nl(); show(IOContext(STDOUT, :limit => true), collect(1:5)); pl_nl();
                         show(IOContext(STDOUT, :limit => true), ["abc$i" for i in 1:30]); pl_nl(); 0)
pl_ctx_limit_matrix() = (show(IOContext(STDOUT, :limit => true), reshape(1:100, 10, 10)); pl_nl(); show(IOContext(STDOUT, :limit => true), reshape(1:1000, 10, 10, 10)); pl_nl(); 0)
pl_ctx_limit_others() = (show(IOContext(STDOUT, :limit => true), Dict(i => i for i in 1:5)); pl_nl(); show(IOContext(STDOUT, :limit => true), Set(1:5)); pl_nl();
                         show(IOContext(STDOUT, :limit => true), 1:100); pl_nl(); show(IOContext(STDOUT, :limit => true), "a"^50); pl_nl(); 0)
pl_ctx_two() = (show(IOContext(STDOUT, :compact => true, :limit => true), collect(0.1:0.1:3.0)); pl_nl(); 0)
pl_ctx_plain_limit() = (show(IOContext(STDOUT, :limit => true, :displaysize => (24, 80)), PL_TP, reshape(1:100, 10, 10)); pl_nl();
                        show(IOContext(STDOUT, :limit => true, :displaysize => (10, 80)), PL_TP, collect(1:100)); pl_nl();
                        show(IOContext(STDOUT, :limit => true, :displaysize => (24, 60)), PL_TP, reshape(collect(1.5:1.0:60.5), 3, 20)); pl_nl(); 0)
pl_ctx_query() = (io = IOContext(STDOUT, :limit => true, :compact => false); (get(io, :limit, false) ? 1 : 0) + (get(io, :compact, true) ? 10 : 0) +
                  (haskey(io, :limit) ? 100 : 0) + (haskey(io, :color) ? 1000 : 0) + (io[:limit] ? 10000 : 0))
pl_ctx_nested() = (io = IOContext(IOContext(STDOUT, :compact => true), :limit => true, :compact => false); (get(io, :limit, false) ? 1 : 0) + (get(io, :compact, true) ? 10 : 0))
pl_ctx_displaysize() = (io = IOContext(STDOUT, :displaysize => (30, 100)); d = displaysize(io); d[1] + d[2])

const PLAIN_CASES = [pl_matrix_int, pl_matrix_float, pl_matrix_compact_floats, pl_matrix_float32, pl_matrix_string, pl_matrix_bool, pl_matrix_any, pl_matrix_complex,
                     pl_matrix_complex_float, pl_matrix_rational, pl_matrix_wide, pl_matrix_exponents, pl_column, pl_empty, pl_3d, pl_vector_int, pl_vector_float,
                     pl_vector_string, pl_vector_any, pl_range, pl_dict, pl_set, pl_scalars, pl_struct, pl_wrappers, pl_chars, pl_sprint_any,
                     pl_ctx_compact, pl_ctx_limit_vector, pl_ctx_limit_matrix, pl_ctx_limit_others, pl_ctx_two, pl_ctx_plain_limit, pl_ctx_query, pl_ctx_nested,
                     pl_ctx_displaysize]

@testset "text/plain and the properties of a context" begin
    @testset "$(nameof(f))" for f in PLAIN_CASES
        status, detail = static_status(f)
        @test (status, first(replace(string(detail), '\n' => ' '), 300)) == (:ok, "")
    end
end

# `display(x)` of Julia writes to the terminal that Julia was started with, which a test can't capture: the output of the program is compared with the `text/plain` text instead
function compiled_stdout(f)
    main = StaticCompilerOverrides.make_main(f)
    exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)))
    return read(`$exe`, String)
end
pl_display_values() = (display([1 2; 3 4]); display([1, 2, 3]); display(3); display("a"); display(1.5); display(:s); display(nothing); display(Dict(:a => 1)); display(1:3); 0)
pl_display_floats() = (display([1.5 2.0; 3.0 0.1+0.2]); display(Any[1, "a", 2.5]); display(reshape(1:8, 2, 2, 2)); 0)
@testset "display" begin
    expected = join(sprint(show, PL_TP, x) * "\n" for x in Any[[1 2; 3 4], [1, 2, 3], 3, "a", 1.5, :s, nothing, Dict(:a => 1), 1:3]) * "0\n"
    @test compiled_stdout(pl_display_values) == expected
    expected = join(sprint(show, PL_TP, x) * "\n" for x in Any[[1.5 2.0; 3.0 0.1+0.2], Any[1, "a", 2.5], reshape(1:8, 2, 2, 2)]) * "0\n"
    @test compiled_stdout(pl_display_floats) == expected
end

# structured matrices (the module `LinearAlgebra` is loaded before this package in the tests, so its types are written without the module, as Julia does: when a module is loaded
# after the package, its types are written with the module, see `show.jl`)
pl_structured() = (pl_text(Diagonal([1, 2, 3])); pl_text(UpperTriangular([1 2 3; 4 5 6; 7 8 9])); pl_text(LowerTriangular([1.5 2.0; 3.0 4.0])); pl_text(Tridiagonal([1, 2], [3, 4, 5], [6, 7]));
                   pl_text(Symmetric([1 2; 2 3])); pl_text(Hermitian([1.0 2.0im; -2.0im 3.0])); 0)
@testset "structured matrices" begin
    expected = join(sprint(show, PL_TP, x) * "\n" for x in Any[Diagonal([1, 2, 3]), UpperTriangular([1 2 3; 4 5 6; 7 8 9]), LowerTriangular([1.5 2.0; 3.0 4.0]),
                                                               Tridiagonal([1, 2], [3, 4, 5], [6, 7]), Symmetric([1 2; 2 3]), Hermitian([1.0 2.0im; -2.0im 3.0])]) * "0\n"
    @test compiled_stdout(pl_structured) == expected
end

# the keyword `context` of `sprint` with a pair that is written in the call: its value is not known to the compiler inside the method of `sprint` (not yet supported for the show of an array)
pl_sprint_context_vector() = (println(sprint(show, [1, 2, 3]; context = :compact => true)); 0)
@testset "sprint with a context in the call" begin
    @test_broken static_status(pl_sprint_context_vector)[1] == :ok
end

# the two letters of the category of a character, from the table of categories (the same as utf8proc's for every character)
pl_category_abbrevs() = (n = 0; for cp in 0x00:0x2ff; n = 31 * n + codeunit(Base.Unicode.category_abbrev(Char(cp)), 1) + 7 * codeunit(Base.Unicode.category_abbrev(Char(cp)), 2); end; n)
@testset "categories of characters" begin
    @test static_status(pl_category_abbrevs)[1] == :ok
end
