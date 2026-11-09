# `show` of arrays of more than one dimension (`println(A)`, `repr(A)`, `string(A)`, "$A"), which is Base's own: its code for matrices makes the matrix a value of the
# type `Any` for the compiler (`inferencebarrier`), and gets the type of the elements from the `IOContext` (`:typeinfo`), which are what the methods in `show.jl`
# change. What is written is compared with what Julia writes.

struct ArrPoint; x::Int; y::Int; end
Base.show(io::IO, p::ArrPoint) = print(io, "P(", p.x, ",", p.y, ")")

ar_int() = (println([1 2; 3 4]); 0)
ar_float64() = (println([1.5 2.0; 3.0 4.25]); 0)
ar_float32() = (println(Float32[1.5 2.0; 3.0 4.25]); 0)       # (the type of the elements is in the context: no `f0`)
ar_string() = (println(["a" "bc"; "d" "e"]); 0)
ar_bool() = (println([true false; false true]); 0)
ar_char() = (println(['a' 'b'; 'c' 'd']); 0)
ar_symbol() = (println([:a :b; :c :d]); 0)
ar_any() = (println(Any[1 "a"; 2.5 :s]); 0)
ar_union() = (println(Union{Nothing,Int}[1 nothing; 3 4]); 0)
ar_complex() = (println([1+2im 3-1im; 0im 1im]); 0)
ar_rational() = (println([1//2 3//4; 1//1 2//3]); 0)
ar_shapes() = (println(reshape([7], 1, 1)); println([1 2 3]); println(reshape([1, 2, 3], 3, 1)); 0)
ar_empty() = (println(zeros(0, 3)); println(Matrix{Int}(undef, 0, 0)); 0)
ar_3d() = (println(reshape(1:8, 2, 2, 2)); println(reshape(collect(1.0:8.0), 2, 2, 2)); 0)
ar_4d() = (println(reshape(1:16, 2, 2, 2, 2)); 0)
ar_bitmatrix() = (println(BitMatrix([true false; false true])); 0)
ar_wrappers() = (println(reshape(1:6, 2, 3)); println(transpose([1 2; 3 4])); println([1.0 2.0; 3.0 4.0]'); println(view([1 2 3; 4 5 6], 1:2, 2:3)); 0)
ar_linalg() = (println(Symmetric([1 2; 2 3])); println(Diagonal([1, 2])); println(Matrix(1.0I, 2, 2)); 0)
ar_repr() = (println(repr([1 2; 3 4])); println(string([1.5 2.0; 3.0 4.0])); println("A = $([1 2; 3 4])"); 0)
ar_nested() = (println([[1 2; 3 4], [5 6; 7 8]]); println(([1 2; 3 4], 1)); println(Dict(:a => [1 2; 3 4])); 0)
ar_zeros() = (println(zeros(2, 2)); println(ones(Int, 2, 3)); 0)
ar_zero_dim() = (println(fill(5)); 0)
ar_struct_elements() = (println([ArrPoint(1, 2) ArrPoint(3, 4); ArrPoint(5, 6) ArrPoint(7, 8)]); 0)
ar_sizes() = (println(rand(3, 3) |> size); println(size(zeros(2, 3, 4))); 0)

const ARRAY_CASES = [ar_int, ar_float64, ar_float32, ar_string, ar_bool, ar_char, ar_symbol, ar_any, ar_union, ar_complex, ar_rational, ar_shapes, ar_empty, ar_3d,
                     ar_4d, ar_bitmatrix, ar_wrappers, ar_linalg, ar_repr, ar_nested, ar_zeros, ar_zero_dim, ar_struct_elements, ar_sizes]

@testset "show of arrays of more than one dimension" begin
    @testset "$(nameof(f))" for f in ARRAY_CASES
        status, detail = static_status(f)
        @test (status, first(replace(string(detail), '\n' => ' '), 300)) == (:ok, "")
    end
end
