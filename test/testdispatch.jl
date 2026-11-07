# Dynamic dispatch on abstract types: resolved when compiling, by union splitting over the concrete subtypes (`src/dispatch.jl`)
using Test
if Base.find_package("StaticCompilerOverrides") === nothing
    include(joinpath(@__DIR__, "..", "src", "StaticCompilerOverrides.jl"))
    using .StaticCompilerOverrides
else
    using StaticCompilerOverrides
end

abstract type DAnimal end
abstract type DPet <: DAnimal end
struct DDog <: DPet; age::Int; end
struct DCat <: DPet; age::Int; end
struct DCow <: DAnimal; weight::Float64; end
struct DFish <: DAnimal; n::Int; end
struct DHen <: DAnimal; eggs::Int; end
struct DBee <: DAnimal; hives::Int; end
dvalue(a::DDog) = a.age * 10
dvalue(a::DCat) = a.age * 20
dvalue(a::DCow) = round(Int, a.weight)
dvalue(a::DFish) = a.n
dvalue(a::DHen) = a.eggs + 1000
dvalue(a::DBee) = a.hives * 7
dkind(::DPet) = 1
dkind(::DAnimal) = 2
dname(a::DDog) = "dog"
dname(a::DCow) = "cow"
dname(a::DAnimal) = "other" # (the types without a method of their own)
dmix(a::DDog, b::DCat) = 1
dmix(a::DCat, b::DDog) = 2
dmix(a::DAnimal, b::DAnimal) = 3
dsize(a::DDog) = 1          # (results of different types)
dsize(a::DCow) = 2.5
dsize(a::DAnimal) = "big"
const DALL = DAnimal[DDog(3), DCat(2), DCow(450.5), DFish(12), DHen(5), DBee(2)]

abstract type DOpen end        # (a parametric subtype, whose instances can't be listed)
struct DOpenA{T} <: DOpen; x::T; end
struct DOpenB <: DOpen; x::Int; end
struct DOpenC <: DOpen; x::Int; end
struct DOpenD <: DOpen; x::Int; end
struct DOpenE <: DOpen; x::Int; end
dopen(a::DOpenA) = 1
dopen(a::DOpenB) = 2
dopen(a::DOpenC) = 3
dopen(a::DOpenD) = 4
dopen(a::DOpenE) = 5

@testset "Dispatch on abstract types" begin
    zoo() = DALL # (types that are not known when compiling)
    @testset "six types, two levels of abstract types" begin
        @test static_result(() -> (s = 0; for a in zoo(); s += dvalue(a); end; s)) == sum(dvalue, DALL)
        @test static_result(() -> sum(dvalue, zoo())) == sum(dvalue, DALL)
    end
    @testset "fallbacks and specificity" begin
        @test static_result(() -> sum(dkind, zoo())) == sum(dkind, DALL)
        @test static_result(() -> sum(a -> length(dname(a)), zoo())) == sum(a -> length(dname(a)), DALL)
    end
    @testset "two arguments" begin
        f() = (z = zoo(); s = 0; for a in z, b in z; s += dmix(a, b); end; s)
        @test static_result(f) == f()
    end
    @testset "results of different types" begin
        f() = (s = 0.0; for a in zoo(); r = dsize(a); s += r isa Int ? r : r isa Float64 ? r : length(r); end; s)
        @test static_result(() -> round(Int, f())) == round(Int, f())
    end
    @testset "Union{Nothing,T}, and a Dict of them" begin
        f() = (d = Dict{Int,DAnimal}(); d[1] = DALL[1]; d[2] = DALL[3]; s = 0; for (k, a) in d; s += k * dvalue(a); end; s)
        @test static_result(f) == f()
        g() = (x::Union{Nothing,DAnimal} = DALL[2]; x === nothing ? 0 : dvalue(x))
        @test static_result(g) == g()
    end
    @testset "abstract types that can't be listed stay dynamic (and are rejected)" begin
        f() = (v = DOpen[DOpenB(1), DOpenB(2)]; sum(dopen, v))
        @test static_status(f)[1] == :compile_error
        h() = (v = Any[1, 2.5]; sum(x -> x isa Int ? 1 : 2, v))
        @test static_status(h)[1] == :ok # (the tests of a type are not dispatch)
    end
    @testset "with the collector in stress mode" begin
        @test static_result(() -> sum(dvalue, zoo()); gc = 2) == sum(dvalue, DALL)
    end
end
