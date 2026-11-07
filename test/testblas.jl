# BLAS through libblastrampoline: the program uses the library that was forwarded to when it was compiled
using Test, LinearAlgebra
if Base.find_package("StaticCompilerOverrides") === nothing
    include(joinpath(@__DIR__, "..", "src", "StaticCompilerOverrides.jl"))
    using .StaticCompilerOverrides
else
    using StaticCompilerOverrides
end

blas_work() = (a = [sin(i + 2j) for i in 1:30, j in 1:30]; b = [cos(i - j) for i in 1:30, j in 1:30];
               x = (a + 10I) \ b[:, 1];
               round(Int, 1000 * (sum(a * b) + sum(x) + det(a[1:3, 1:3]) + sum(eigvals(Symmetric(a[1:4, 1:4]))) + dot(b[:, 1], b[:, 2]))))

@testset "BLAS" begin
    @testset "libblastrampoline, loaded when needed" begin
        @test static_result(blas_work) == blas_work()
    end
    # a program that does not use BLAS does not load it
    @testset "not loaded when not used" begin
        exe_dir = mktempdir()
        main = StaticCompilerOverrides.make_main(() -> 1 + 1)
        exe = compile_executable(main, (Int, Ptr{Ptr{UInt8}}), exe_dir, string(nameof(main)))
        @test !occursin("blastrampoline", String(read(exe)))
    end
    # the library that backs it is what was set when compiling: Accelerate, where it is there (it forwards some of BLAS
    # and LAPACK, so the libraries are used together, as in Julia)
    @testset "Accelerate" begin
        if Sys.isapple() && Base.find_package("AppleAccelerate") !== nothing
            Core.eval(Main, :(using AppleAccelerate))
            before = BLAS.get_config()
            try
                Base.invokelatest(Main.AppleAccelerate.load_accelerate)
                @test any(l -> occursin("Accelerate", l.libname), BLAS.get_config().loaded_libs)
                @test static_result(blas_work) == blas_work()
            finally
                path = first(l.libname for l in before.loaded_libs)
                BLAS.lbt_forward(path; clear = true)
            end
        else
            @info "Skipping the Accelerate test: AppleAccelerate is not installed"
        end
    end
end
