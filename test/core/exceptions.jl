# `throw`, `try`, `catch`, `finally`, `rethrow`, and the errors of Base: what a compiled program catches and when it runs `finally`, compared with Julia.

@noinline thrower(x::Int) = x > 0 ? throw(ArgumentError("boom")) : x
@noinline thrower3(x::Int) = x == 1 ? throw(ArgumentError("a")) : x == 2 ? throw(DomainError(x, "b")) : [1, 2, 3][x + 10]
@noinline thrower2(x::Int) = x == 1 ? throw(ArgumentError("a")) : throw(DomainError(x, "b"))
@noinline deep(n::Int) = n == 0 ? thrower(1) : [n; deep(n - 1)...][1] # allocates on the way

@testset "Exceptions" begin
    check_cases([
    "try/catch"             => () -> (try; thrower(Base.inferencebarrier(1)); catch; 7; end),
    "try no throw"          => () -> (try; thrower(Base.inferencebarrier(0)); catch; 7; end),
    "try/finally"           => () -> (r = Ref(0); try; r[] += 1; finally; r[] += 10; end; r[]),
    "catch and finally"     => () -> (r = Ref(0); try; try; thrower(Base.inferencebarrier(1)); finally; r[] += 10; end; catch; r[] += 1; end; r[]),
    "rethrow"               => () -> (try; try; thrower(Base.inferencebarrier(1)); catch; rethrow(); end; catch; 5; end),
    "nested try"            => () -> (try; try; thrower(Base.inferencebarrier(1)); catch; thrower(Base.inferencebarrier(2)); end; catch; 9; end),
    "throw through frames"  => () -> (try; deep(Base.inferencebarrier(5)); catch; -1; end),
    "catch in loop"         => () -> (s = 0; for i in 1:5; try; thrower(Base.inferencebarrier(i % 2)); catch; s += i; end; end; s),
    "catch typed 3 types"   => () -> (s = 0; for i in 1:3; s += try; thrower3(Base.inferencebarrier(i)); 0; catch e; e isa ArgumentError ? 1 : e isa DomainError ? 10 : e isa BoundsError ? 100 : 1000; end; end; s),
    "catch typed"           => () -> (try; thrower2(Base.inferencebarrier(2)); catch e; e isa DomainError ? 2 : 1; end),
    "BoundsError caught"    => () -> (try; [1, 2, 3][Base.inferencebarrier(5)::Int]; catch; 3; end),
    "InexactError caught"   => () -> (try; Int8(Base.inferencebarrier(300)::Int); catch; 4; end),
    "DivideError caught"    => () -> (try; div(1, Base.inferencebarrier(0)::Int); catch; 5; end),
    "error() caught"        => () -> (try; error("x"); catch; 7; end),
    "throw caught"          => () -> (try; throw(ArgumentError("x")); catch e; e isa ArgumentError ? 1 : 0; end),
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
