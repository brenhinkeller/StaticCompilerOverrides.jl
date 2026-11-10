# Global variables that are not `const`: read and written as the `value` of their binding, which is copied into the binary with the value that it has when compiling.
# (Each case has globals of its own: `static_status` compiles first, and then runs the function in Julia, which changes them.)

struct GlPoint; x::Int; y::Float64; end

gl_int = 5
gl_int_w = 5
gl_typed::Int = 7
gl_typed_w::Int = 7
gl_counter = 0
gl_counter_loop = 0
gl_string = "hello"
gl_retyped = 1
gl_vec::Vector{Int} = [1, 2, 3]
gl_vec_replace::Vector{Int} = [1, 2, 3]
gl_dict::Dict{String,Int} = Dict("a" => 1)
gl_point::GlPoint = GlPoint(1, 2.5)
gl_many::Vector{Int} = [0]
gl_shared = 10
gl_float = 1.5
global gl_declared_only
gl_ref = Ref(0)
gl_untyped_vec = [1, 2, 3]

gl_read() = gl_int + 1
gl_write() = (global gl_int_w = 9; gl_int_w)
gl_typed_read() = gl_typed + 1
gl_typed_write() = @opaque((global gl_typed_w = 11; gl_typed_w + 1))
gl_bump() = (global gl_counter += 1; gl_counter)
gl_bump3() = (gl_bump(); gl_bump(); gl_bump())
gl_loop() = (s = 0; for i in 1:5; global gl_counter_loop += i; s += gl_counter_loop; end; s)
gl_strings() = (global gl_string = gl_string * "!"; length(gl_string))
gl_retype() = (a = gl_retyped + 1; global gl_retyped = "now a string"; a + length(gl_retyped))
gl_vec_push() = @opaque((push!(gl_vec, 4); sum(gl_vec)))
gl_vec_new() = @opaque((global gl_vec_replace = [10, 20]; sum(gl_vec_replace)))
gl_dict_add() = (gl_dict["b"] = 2; sum(values(gl_dict)))
gl_point_update() = (global gl_point = GlPoint(gl_point.x + 1, gl_point.y * 2); gl_point.x + Int(gl_point.y))
gl_many_allocations() = @opaque((for i in 1:2000; global gl_many = [i, i + 1, i + 2]; end; sum(gl_many)))
gl_two_functions() = (global gl_shared += 1; gl_shared_double() + gl_shared)
gl_shared_double() = (global gl_shared *= 2; gl_shared)
gl_float_update() = @opaque((global gl_float += 0.25; round(Int, 100 * gl_float)))
gl_declared() = (global gl_declared_only = 5; gl_declared_only + 1)
gl_ref_untyped() = (gl_ref[] += 1; gl_ref[])
gl_vec_untyped() = (push!(gl_untyped_vec, 9); sum(gl_untyped_vec))

@testset "Global variables that are not const" begin
    check_cases([gl_read, gl_write, gl_typed_read, gl_typed_write, gl_bump3, gl_loop, gl_strings, gl_retype, gl_vec_push, gl_vec_new, gl_dict_add, gl_point_update, gl_many_allocations, gl_two_functions, gl_float_update, gl_declared])

    # a global of a type that is not known (`Any`) that holds a value that is not of the registered types can't be used: and the message says why
    @testset "untyped globals of other types" begin
        status, detail = static_status(gl_ref_untyped)
        @test status == :compile_error
        @test occursin("global variables that are not `const`", detail) || occursin("not `const`", detail)
        status, detail = static_status(gl_vec_untyped)
        @test status == :compile_error
        @test occursin("not `const`", detail)
    end
end
