# Helpers of the tests of packages: the programs compile to executables, and have to print what Julia gives for the same code.

using Test, Random, Statistics, LinearAlgebra
using StaticCompilerOverrides

# (libm can differ from Julia's in the last bit: results are compared to 6 digits)
r6(x) = round(Int, 1e6 * x)
data() = Float64[sin(i) * 3 + i / 10 for i in 1:50]
dataN() = (x = data(); x[7] = NaN; x[20] = NaN; x)
weights50() = Float64[1 + (i % 3) for i in 1:50]

"""
    check_cases(cases; broken = ())

Each `name => f` of `cases` is a testset: the program of the zero-argument function `f` has to compile, and run to the same output as `f()`.
The names in `broken` are the ones that don't yet (when one does, it is reported as an unexpected pass, and has to be taken off the list).
"""
function check_cases(cases; broken = ())
    @testset "$name" for (name, f) in cases
        if name in broken
            @test_broken static_status(f)[1] == :ok
        else
            status, detail = static_status(f)
            @test (status, first(replace(string(detail), '\n' => ' '), 300)) == (:ok, "")
        end
    end
end
