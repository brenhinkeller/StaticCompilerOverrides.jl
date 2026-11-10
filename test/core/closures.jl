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
