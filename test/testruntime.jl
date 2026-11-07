# The minimal runtime of statically compiled code (src/runtime.jl): allocation without a GC, and
# exceptions. Included by runtests.jl, after corpus.jl has loaded StaticCompilerOverrides.
using Test

# compile `main(argc, argv)`, run it, and return what it prints
function run_main(main; dir = mktempdir())
    exe = compile_executable(main, (Int, Ptr{Ptr{UInt8}}), dir, string(nameof(main)))
    return readchomp(`$exe`)
end

@testset "Runtime: allocation" begin
    # all of these used to fail to link
    @eval alloc_vector(argc::Int, argv::Ptr{Ptr{UInt8}}) = (printf(c"%d\n", sum(collect(1:argc+3))); 0)
    @eval alloc_push(argc::Int, argv::Ptr{Ptr{UInt8}}) = (v = Int[]; for i in 1:20; push!(v, i); end; printf(c"%d\n", sum(v)); 0)
    @eval alloc_dict(argc::Int, argv::Ptr{Ptr{UInt8}}) = (d = Dict(1 => 2, 3 => 4); printf(c"%d\n", d[1] + d[3]); 0)
    @eval alloc_string(argc::Int, argv::Ptr{Ptr{UInt8}}) = (printf(c"%d\n", length(string(12345))); 0)
    @test run_main(alloc_vector) == "10"
    @test run_main(alloc_push) == "210"
    @test run_main(alloc_dict) == "6"
    @test run_main(alloc_string) == "5"
end

@testset "Runtime: exceptions" begin
    @eval @noinline rt_thrower(x::Int) = x > 0 ? throw(ArgumentError("boom")) : x
    @eval rt_catch(argc::Int, argv::Ptr{Ptr{UInt8}}) = (r = try; rt_thrower(argc); catch; 7; end; printf(c"%d\n", r); 0)
    @eval rt_nocatch(argc::Int, argv::Ptr{Ptr{UInt8}}) = (r = try; rt_thrower(argc - 1); catch; 7; end; printf(c"%d\n", r); 0)
    @eval rt_finally(argc::Int, argv::Ptr{Ptr{UInt8}}) = (r = Ref(0); try; try; rt_thrower(argc); finally; r[] += 10; end; catch; r[] += 1; end; printf(c"%d\n", r[]); 0)
    @eval rt_rethrow(argc::Int, argv::Ptr{Ptr{UInt8}}) = (r = try; try; rt_thrower(argc); catch; rethrow(); end; catch; 5; end; printf(c"%d\n", r); 0)
    @test run_main(rt_catch) == "7"
    @test run_main(rt_nocatch) == "0"
    @test run_main(rt_finally) == "11"
    @test run_main(rt_rethrow) == "5"

    # no handler: report and exit with a failure status, rather than crashing
    @eval rt_uncaught(argc::Int, argv::Ptr{Ptr{UInt8}}) = (rt_thrower(argc); 0)
    exe = compile_executable(rt_uncaught, (Int, Ptr{Ptr{UInt8}}), mktempdir(), "rt_uncaught")
    p = run(ignorestatus(pipeline(`$exe`; stderr = devnull, stdout = devnull)))
    @test p.exitcode == 1
end
