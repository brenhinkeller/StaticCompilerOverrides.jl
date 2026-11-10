# Idioms that code of packages needs, that Base's own code seldom does (found compiling Distributions.jl and NaNStatistics.jl): `invokelatest`, `@assert` with a message, deprecated methods.

invokelatest_square(x) = x * x
@testset "invokelatest" begin
    @test static_result(() -> Base.invokelatest(invokelatest_square, Base.inferencebarrier(7)::Int)) == 49
end

assert_message(n::Int) = (@assert n > 0 "n = $n is not positive"; n + 1)
Base.@deprecate deprecated_old(n) deprecated_new(n)
deprecated_new(n) = n + 100
@testset "Assertions and deprecations" begin
    @test static_result(() -> assert_message(Base.inferencebarrier(3))) == 4
    # a message that is not a literal is a `String`, and shown by the program when the assertion fails
    main = StaticCompilerOverrides.make_main(() -> (try; assert_message(Base.inferencebarrier(-5)); catch e; e isa AssertionError ? length(e.msg) : -1; end))
    exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)))
    @test parse(Int, readchomp(`$exe`)) == length("n = -5 is not positive")
    # (the warning of a deprecated method, and the options of the Julia that runs, are not in the program)
    @test static_result(() -> deprecated_old(Base.inferencebarrier(1))) == 101
end
