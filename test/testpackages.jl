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

# What was found compiling StatsBase.jl: `reshape(x, :, n)` (which shows `Colon()` in its error message), a `Symbol` that
# is not known when compiling (AliasTables, which `sample` uses, makes messages with one), boxed floats and small integers
# (the value in a `DomainError`), and `IdDict` (with `deepcopy`)
symbol_name(x::Vector{Symbol}) = x[1]
mutable struct DeepNode
    value::Int
    next::Union{Nothing,DeepNode}
end

sb_case1() = (y = Base.inferencebarrier(1.5)::Float64; z = Base.inferencebarrier(Int8(3))::Int8; x = Any[y, 2.5f0, z]; Int(x[1] === y) + 10 * Int(x[2] === 2.5f0) + 100 * Int(x[3] === z) + 1000 * Int(x[1] === x[2]))
sb_case2() = (d = IdDict{Vector{Int},Int}(); a = [1]; b = [1]; d[a] = 1; d[b] = 2; d[a] + 10 * d[b] + 100 * length(d) + 1000 * Int(haskey(d, [1])))
sb_case3() = (d = IdDict{Vector{Int},Int}(); ks = [[i] for i in 1:40]; for (i, k) in enumerate(ks); d[k] = i; end; for k in ks[1:2:end]; delete!(d, k); end; s = 0; for (k, v) in d; s += k[1] * v; end; 100000 * length(d) + s)
sb_case4() = (d = IdDict{Vector{Int},Int}(); a = [1]; get!(d, a, 3) + get!(() -> 9, d, a) + pop!(d, a) + length(d))
sb_case5() = (d = IdDict{Int,Int}(); for i in 1:100; d[i] = i * i; end; d[7] + length(d))
sb_case6() = (a = [[1, 2], [3]]; b = deepcopy(a); b[1][1] = 9; a[1][1] * 10 + b[1][1] + length(b[2]))
sb_case7() = (x = [1, 2]; b = deepcopy([x, x]); b[1][1] = 7; b[2][1])
sb_case8() = (d = Dict(1 => [1, 2]); e = deepcopy(d); e[1][1] = 8; d[1][1] * 10 + e[1][1])
sb_case9() = (a = ["a", "bc"]; length(deepcopy(a)[2]))

@testset "Found compiling StatsBase.jl" begin
    @testset "reshape with a colon" begin
        @static_test size(reshape(Float64[1, 2, 3, 4, 5, 6], :, 2), 1)
        @static_test size(reshape(Float64[1, 2, 3, 4, 5, 6], 3, :), 2)
    end
    @testset "functions and Colon() are shown" begin
        @test static_status(() -> (print(sin); print(' '); print(:); print(' '); print(typeof(sin)); print(' '); println((:, identity)); 0)) == (:ok, "")
        @static_test ncodeunits(string(sin, identity, :))
    end
    @testset "Symbols that are not known when compiling" begin
        f = () -> (v = Base.inferencebarrier([:abcd, :ef])::Vector{Symbol}; s = symbol_name(v); ncodeunits(string("x ", s, " y")) + 100 * ncodeunits(sprint(print, s)))
        @static_test f()
        @test static_status(() -> (v = Base.inferencebarrier([:abcd])::Vector{Symbol}; print(symbol_name(v)); 0)) == (:ok, "")
    end
    @testset "boxed floats and small integers" begin
        boxed(x) = Base.inferencebarrier(x)
        @test static_result(() -> (a = boxed(1.5)::Float64; b = boxed(Float32(2.5))::Float32; c = boxed(Int8(3))::Int8; d = boxed(UInt16(4))::UInt16; Int(round(a + b)) + c + d)) == 11
        @static_test sb_case1()
    end
    @testset "IdDict" begin
        @static_test sb_case2()
        @static_test sb_case3()
        @static_test sb_case4()
        @static_test sb_case5()
    end
    @testset "deepcopy" begin
        @static_test sb_case6()
        @static_test sb_case7()
        @static_test sb_case8()
        @static_test sb_case9()
    end
end

# Found compiling Thermochron.jl: an immutable struct of many fields (a `SphericalHe` is 392 bytes) that is a constant: its fields
# beyond 256 bytes were looked for as objects of their own, and not found
struct ManyFields
    a1::Vector{Int}; a2::Vector{Int}; a3::Vector{Int}; a4::Vector{Int}; a5::Vector{Int}; a6::Vector{Int}; a7::Vector{Int}; a8::Vector{Int}
    b1::Vector{Int}; b2::Vector{Int}; b3::Vector{Int}; b4::Vector{Int}; b5::Vector{Int}; b6::Vector{Int}; b7::Vector{Int}; b8::Vector{Int}
    c1::Vector{Int}; c2::Vector{Int}; c3::Vector{Int}; c4::Vector{Int}; c5::Vector{Int}; c6::Vector{Int}; c7::Vector{Int}; c8::Vector{Int}
    d1::Vector{Int}; d2::Vector{Int}; d3::Vector{Int}; d4::Vector{Int}; d5::Vector{Int}; d6::Vector{Int}; d7::Vector{Int}; d8::Vector{Int}
    e1::Vector{Int}; e2::Vector{Int}; e3::Vector{Int}; e4::Vector{Int}; e5::Vector{Int}; e6::Vector{Int}; e7::Vector{Int}; e8::Vector{Int}
    name::String
end
const MANY = ManyFields((([i] for i in 1:40)..., "many")...)
many_sum(m::ManyFields) = m.a1[1] + m.b8[1] + m.c3[1] + m.d8[1] + m.e1[1] + m.e8[1] + ncodeunits(m.name)
@testset "Large constant structs" begin
    @test sizeof(MANY) > 256
    @static_test many_sum(MANY)
end
