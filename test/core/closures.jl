# Calls of functions that are not known when compiling (src/closures.jl): closures in collections, in fields and in boxes, `Any` that holds a function. The cases are compiled one by one:
# the functions that a program has are looked for in the program, so what is tested is each program on its own.

cov_adder(k) = x -> x + k
const COV_ADD3 = cov_adder(3)
const COV_ANYF = Any[cov_adder(5), sin]
const COV_DICTF = Dict{String,Function}("a" => cov_adder(1), "b" => cos)

@testset "Closures and functions that are not known" begin
    mutable struct Holder; f::Function; end
    make_adder(k) = x -> x + k
    make_counter() = (n = opaque(0); () -> (n += 1)) # (the start is `opaque`: with the constant 0 the compiler runs the counter)
    apply_all(fs, x) = map(f -> f(x), fs)
    kw(x; k = 2) = x * k
    any_function = any_value
    FS = Function[sin, cos, x -> 2x]
    check_cases([
        "a closure that captures" => @opaque(() -> make_adder(3)(4)),
        "a variable that is boxed" => @opaque(() -> (c = make_counter(); c(); c(); c())),
        "a variable that is changed" => @opaque(() -> (x = 1; f = () -> x; x = 2; f())),
        "closures made in a loop" => @opaque(() -> (fs = [x -> x + i for i in 1:3]; sum(f(10) for f in fs))),
        "a vector of two closures"     => () -> (fs = [x -> x + 1, x -> x * 2]; fs[1](fs[2](5))),
        "a Vector{Function}" => @opaque(() -> (s = 0.0; for f in Function[sin, cos, x -> 2x]; s += f(1.0); end; round(Int, 1000s))),
        "a Vector{Function} in a local" => @opaque(() -> (s = 0.0; for f in FS; s += f(1.0); end; round(Int, 1000s))),
        "a function of type Any"       => () -> any_function(sin)(1.0) > 0,
        "a closure of type Any"        => () -> any_function(x -> x + 1)(2),
        "a Dict of functions" => @opaque(() -> (d = Dict("a" => sin, "b" => cos); d["b"](0.0) + d["a"](0.0))),
        "a Ref{Function}" => @opaque(() -> (r = Ref{Function}(sin); r[] = cos; r[](0.0))),
        "a field of type Function" => @opaque(() -> (h = Holder(sin); h.f(0.0) + (h.f = cos; h.f(0.0)))),
        "a closure that calls itself"  => () -> (fib = nothing; fib = n -> n < 2 ? n : fib(n - 1) + fib(n - 2); fib(10)),
        "a local function with keywords, in a closure" => @opaque(() -> (f(x; k = 2) = x * k; g = () -> f(3; k = 4); g())),
        "a constant closure with state" => @opaque(() -> COV_ADD3(4)),
        "a constant Any[closure, sin]" => () -> COV_ANYF[1](1) + COV_ANYF[2](0.0),
        "a constant Dict of closures" => @opaque(() -> COV_DICTF["a"](1) + COV_DICTF["b"](0.0)),
        "functions that are composed" => @opaque(() -> (fs = (x -> x + 1, x -> x * 3); foldl((a, f) -> f(a), fs; init = 2))),
        "a function and Base.Fix2"     => () -> (fs = Function[Base.Fix2(+, 1), Base.Fix1(*, 3)]; fs[1](1) + fs[2](2)),
        "a function that is not called" => () -> (fs = Function[sin, x -> 2x]; length(fs)),
    ]; batch = false)
end

# A variable that a closure takes and that is assigned more than once is a `Core.Box`, which holds anything: what is read from it has the type of what is assigned to the variable (src/inference/boxes.jl)
box_reassigned(x::Int) = (y = x; g = () -> y + 1; y = y * 2; h = () -> y; g() + h())
box_union(flag::Bool, x::Int) = (v = flag ? nothing : [x, x + 1]; cb = () -> v === nothing ? 0 : length(v); if flag; v = [1, 2, 3]; end; cb() + (v === nothing ? 100 : sum(v)))
box_nested(x::Int) = (n = x; inner() = (() -> n * 2)(); n = n + 1; inner())
box_assigned_in_closure(x::Int) = (n = 0; inc = () -> (n += x; nothing); inc(); inc(); n)
box_two(x::Int) = (a = x; b = 1.5; f = () -> a + b; a = a + 1; b = b * 2; f())

@testset "Variables that closures take are boxes of the type of what they hold" begin
    check_cases([
        "a variable assigned from itself"          => @opaque(() -> box_reassigned(opaque(5))),
        "a union that is assigned again, flag"     => @opaque(() -> box_union(opaque(1) == 1, opaque(3))),
        "a union that is assigned again, no flag"  => @opaque(() -> box_union(opaque(1) == 2, opaque(3))),
        "a variable taken by a closure in a closure" => @opaque(() -> box_nested(opaque(4))),
        "a closure that assigns the variable"      => @opaque(() -> box_assigned_in_closure(opaque(4))),
        "two variables of different types"         => @opaque(() -> round(Int, 10 * box_two(opaque(2)))),
    ]; batch = false)
end
