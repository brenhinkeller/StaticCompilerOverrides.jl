# `<:` and `isa` with types that are only known when the program runs: the answers for the types that are in the binary are
# made when compiling, as a table (`define_subtype_table!`), and the builtins `jl_f_issubtype` and `jl_f_isa` look in it.

include("subtype_cases.jl")

@testset "<: and isa with types known at run time" begin
    @static_test sub_count_union()
    @static_test sub_count_abstract()
    @static_test sub_matrix()
    @static_test sub_isa(SubAnimal)
    @static_test sub_isa(SUB_PETS)
    @static_test sub_isa_number()
    @static_test sub_isa_type()
    @static_test sub_eltype_broadcast()
end

# With `--check-bounds=yes` (which is how `Pkg.test` runs the tests of a package on CI) the code is not optimized as far, and keeps
# `ptrtoint (inttoptr N)` constants for the types that it names, and `Type{T}` is an object (a `Core.TypeEq`) that has to be in the binary
@testset "<: with the bounds checks on" begin
    script = joinpath(mktempdir(), "subtype_boundscheck.jl")
    write(script, """
        using Test, Random, StaticCompilerOverrides
        include($(repr(joinpath(@__DIR__, "subtype_cases.jl"))))
        print(static_result(sub_eltype_broadcast) == sub_eltype_broadcast() ? "ok" : "wrong")
        """)
    out = read(`$(Base.julia_cmd()) --check-bounds=yes --project=$(Base.active_project()) $script`, String)
    @test endswith(out, "ok")
end
