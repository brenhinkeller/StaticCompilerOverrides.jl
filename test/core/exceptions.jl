# `throw`, `try`, `catch`, `finally`, `rethrow`, and the errors of Base: what a compiled program catches and when it runs `finally`, compared with Julia. The values that decide what is thrown are `opaque` (see `helpers.jl`): with constants, the compiler would run the exceptions itself, and the program would only print the answer.

@noinline thrower(x::Int) = x > 0 ? throw(ArgumentError("boom")) : x
@noinline thrower3(x::Int) = x == 1 ? throw(ArgumentError("a")) : x == 2 ? throw(DomainError(x, "b")) : [1, 2, 3][x + 10]
@noinline thrower2(x::Int) = x == 1 ? throw(ArgumentError("a")) : throw(DomainError(x, "b"))
@noinline deep(n::Int) = n == 0 ? thrower(1) : [n; deep(n - 1)...][1] # allocates on the way

@testset "Exceptions" begin
    check_cases([
    "try/catch"             => () -> (try; thrower(opaque(1)); catch; 7; end),
    "try no throw"          => () -> (try; thrower(opaque(0)); catch; 7; end),
    "try/finally"           => () -> (r = Ref(opaque(0)); try; r[] += 1; finally; r[] += 10; end; r[]),
    "catch and finally"     => () -> (r = Ref(0); try; try; thrower(opaque(1)); finally; r[] += 10; end; catch; r[] += 1; end; r[]),
    "rethrow"               => () -> (try; try; thrower(opaque(1)); catch; rethrow(); end; catch; 5; end),
    "nested try"            => () -> (try; try; thrower(opaque(1)); catch; thrower(opaque(2)); end; catch; 9; end),
    "throw through frames"  => () -> (try; deep(opaque(5)); catch; -1; end),
    "catch in loop"         => () -> (s = 0; for i in 1:5; try; thrower(opaque(i % 2)); catch; s += i; end; end; s),
    "catch typed 3 types"   => () -> (s = 0; for i in 1:3; s += try; thrower3(opaque(i)); 0; catch e; e isa ArgumentError ? 1 : e isa DomainError ? 10 : e isa BoundsError ? 100 : 1000; end; end; s),
    "catch typed"           => () -> (try; thrower2(opaque(2)); catch e; e isa DomainError ? 2 : 1; end),
    "BoundsError caught"    => () -> (try; [1, 2, 3][opaque(5)::Int]; catch; 3; end),
    "InexactError caught"   => () -> (try; Int8(opaque(300)::Int); catch; 4; end),
    "DivideError caught"    => () -> (try; div(1, opaque(0)::Int); catch; 5; end),
    "error() caught"        => () -> (try; opaque(1) > 0 && error("x"); 0; catch; 7; end),
    "throw caught"          => () -> (try; opaque(1) > 0 && throw(ArgumentError("x")); 2; catch e; e isa ArgumentError ? 1 : 0; end),
    ])
end

# no handler: the program reports the exception and exits with a failure status, rather than crashing
@testset "An exception that is not caught" begin
    @eval @noinline rt_thrower(x::Int) = x > 0 ? throw(ArgumentError("boom")) : x
    @eval rt_uncaught(argc::Int, argv::Ptr{Ptr{UInt8}}) = (rt_thrower(argc); 0)
    exe = compile_executable(rt_uncaught, (Int, Ptr{Ptr{UInt8}}), mktempdir(), "rt_uncaught")
    p = run(ignorestatus(pipeline(`$exe`; stderr = devnull, stdout = devnull)))
    @test p.exitcode == 1
end

# `@assert` with a message that is not a literal: a `String`, shown by the program when the assertion fails
assert_message(n::Int) = (@assert n > 0 "n = $n is not positive"; n + 1)
@testset "@assert with a message" begin
    @test static_result(() -> assert_message(opaque(3))) == 4
    main = StaticRuntime.make_main(() -> (try; assert_message(opaque(-5)); catch e; e isa AssertionError ? length(e.msg) : -1; end))
    exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)))
    @test parse(Int, readchomp(`$exe`)) == length("n = -5 is not positive")
end
