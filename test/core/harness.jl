# The functions that look at a program and test it (src/testing.jl, and the introspection functions of src/overrides.jl): `static_status` and how it classifies, running many cases as one program,
# `static_result`, `@static_test`, `undefined_symbols`, `allocation_sites`, `static_code_typed`, `static_code_llvm` and `static_code_native`.

harness_add(n::Int) = n + 1
harness_alloc(n::Int) = sum(collect(1:n))
harness_dynamic() = (io = Base.inferencebarrier(STDOUT)::IO; println(io, 1); 1)
harness_throws() = (Base.inferencebarrier(1) > 0 ? throw(ArgumentError("it is not caught")) : 1)

@testset "static_status" begin
    @test static_status(() -> harness_add(41)) == (:ok, "")
    @testset "what is written is compared too" begin
        @test static_status(() -> (println("a line"); 1)) == (:ok, "")
        @test static_status(() -> (println(stderr, "to the standard error"); 1))[1] == :compile_error # (`stderr` is a global of an abstract type: see `STDERR`)
        @test static_status(() -> (println(STDERR, "to the standard error"); 1)) == (:ok, "")
    end
    # (the generator of the program is not seeded as Julia's is; what is said of a program that fails is in the message, which the log of a test that fails has)
    let (status, detail) = static_status(() -> rand(Int))
        @test (status, status == :mismatch ? "" : first(string(detail), 600)) == (:mismatch, "")
    end
    @test static_status(harness_dynamic)[1] == :compile_error
    @test static_status(harness_throws)[1] == :runtime_error
    @test static_status(harness_dynamic; strict = false)[1] == :runtime_error # (the dynamic call aborts the program)
end

@testset "static_status_batch" begin
    fs = Function[() -> 1 + 1, () -> rand(Int), () -> harness_add(1), harness_dynamic, () -> (println("hi"); 3)]
    batch = static_status_batch(fs)
    @test [s[1] for s in batch] == [:ok, :mismatch, :ok, :compile_error, :ok] || (@info "the second case" batch[2]; false) # (the cases that do not pass do not change those that do)
    @test [s[1] for s in batch] == [static_status(f)[1] for f in fs] # (the same as each on its own: the text of a mismatch has the numbers that were drawn)
    @test static_status_batch(Function[() -> 2]) == [(:ok, "")]
    @test isempty(static_status_batch(Function[]))
    # what each case writes is compared on its own: the standard output and the standard error of the others do not count
    @test all(s -> s == (:ok, ""), static_status_batch(Function[() -> (println("one"); 1), () -> (println(STDERR, "two"); 2), () -> (print("three"); 3)]))
end

@testset "static_result and @static_test" begin
    @test static_result(() -> 41 + 1) == 42
    @test static_result(() -> 2.5) == reinterpret(Int, 2.5)
    @static_test harness_add(1)
    @static_test sum(i -> i^2, 1:10)
end

@testset "undefined_symbols and allocation_sites" begin
    @test isempty(undefined_symbols(() -> harness_add(1)))
    @test "ijl_apply_generic" in undefined_symbols(harness_dynamic)
    @test allocation_sites(harness_add, Tuple{Int}) == 0
    @test allocation_sites(harness_alloc, Tuple{Int}) > 0
end

@testset "the code of a program" begin
    typed = static_code_typed(harness_add, Tuple{Int})
    @test only(typed).second == Int
    llvm = sprint(io -> static_code_llvm(harness_add, Tuple{Int}; io))
    @test occursin("define", llvm) && occursin("harness_add", llvm)
    native = sprint(io -> static_code_native(harness_add, Tuple{Int}; io))
    @test occursin("harness_add", native)
    @test occursin("ret", native)
end
