# What code of packages needs, that Base's own code seldom does (found by compiling Distributions.jl and NaNStatistics.jl): logging, `invokelatest`,
# `@assert` with a message, deprecated methods, and functions of libraries that are called by the name of the library (`src/libraries.jl`).

# (a binary's output on the standard error)
function stderr_of(f)
    main = StaticCompilerOverrides.make_main(f)
    exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)))
    err = IOBuffer()
    run(pipeline(`$exe`; stdout = devnull, stderr = err))
    return String(take!(err))
end

const LOG_LINE = (@__LINE__) + 1
log_message(n::Int) = (n > 1 && @warn "big n" n; @info "info message" n x = 2.5 name = "abc"; @debug "hidden" n; n + 1)
log_interpolated(n::Int) = (@warn "number $n"; @error "bad" maxlog = 1; n + 1)

@testset "Logging" begin
    err = stderr_of(() -> log_message(Base.inferencebarrier(3)))
    lines = split(err, '\n')
    @test lines[1] == "┌ Warning: big n"
    @test lines[2] == "│   n = 3"
    @test startswith(lines[3], "└ @ ") && endswith(lines[3], "testpackages.jl:" * string(LOG_LINE))
    @test lines[4] == "┌ Info: info message"
    @test lines[5:7] == ["│   n = 3", "│   x = 2.5", "│   name = abc"]
    @test !occursin("hidden", err) # (`@debug` is off, as it is in Julia)
    # (not shown when the condition is not met)
    @test !occursin("big n", stderr_of(() -> log_message(Base.inferencebarrier(1))))
    # a message that is made when it is written, and `maxlog` (which is not kept: the message is written each time)
    err = stderr_of(() -> log_interpolated(Base.inferencebarrier(7)))
    @test occursin("┌ Warning: number 7\n", err) && occursin("┌ Error: bad\n", err) && !occursin("maxlog", err)
    # the program goes on, and gives the same result
    @test static_result(() -> log_message(Base.inferencebarrier(3))) == 4
end

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

const TEST_MPFR = Libdl.LazyLibrary("libmpfr")
mpfr_version() = unsafe_string(ccall((:mpfr_get_version, TEST_MPFR), Cstring, ()))
const TEST_LIBM = Libdl.LazyLibrary(Base.libm_name)
@testset "Functions of libraries" begin
    # libm: called by name
    erfc_value(x) = ccall((:erfc, TEST_LIBM), Float64, (Float64,), x)
    f = () -> round(Int, 1e6 * erfc_value(Base.inferencebarrier(0.3)))
    @test static_result(f) == f()
    @test isempty(undefined_symbols(f) ∩ ["ijl_lazy_load_and_lookup", "ijl_load_and_lookup"])
    # another library: loaded when the program runs, from the path that it had when compiling
    if Libdl.dlopen("libmpfr", throw_error = false) !== nothing
        main = StaticCompilerOverrides.make_main(() -> (length(mpfr_version())))
        exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)))
        @test parse(Int, readchomp(`$exe`)) == length(mpfr_version())
    else
        @info "Skipping the test of another library: libmpfr is not found"
    end
end
