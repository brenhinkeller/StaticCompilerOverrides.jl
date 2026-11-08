# The types and functions of `testsubtype.jl`, which the test with the bounds checks on runs in a process of its own

abstract type SubAnimal end
struct SubDog <: SubAnimal; x::Int; end
struct SubCat <: SubAnimal; y::Float64; end
struct SubFish <: SubAnimal; z::Int; end
struct SubRock; end
const SUB_PETS = Union{SubDog, SubCat}
const SUB_ZOO = Union{SubDog, SubCat, SubFish, SubRock}[SubDog(1), SubCat(2.0), SubFish(3), SubRock()]

# (the types are made values the compiler can't see through, with `inferencebarrier`)
sub_types() = Base.inferencebarrier([SubDog, SubCat, SubFish, SubRock, SubAnimal])::Vector{DataType}
sub_count_union() = sum(Int(t <: SUB_PETS) for t in sub_types())
sub_count_abstract() = sum(Int(t <: SubAnimal) for t in sub_types())
function sub_matrix()
    ts = sub_types()
    s = 0
    for (i, a) in enumerate(ts), (j, b) in enumerate(ts)
        s += (a <: b) * (10 * i + j)
    end
    return s
end
function sub_isa(::Type{T}) where {T}
    t = Base.inferencebarrier(T)
    s = 0
    for z in SUB_ZOO
        s = 2s + Int(isa(z, t))
    end
    return s
end
sub_isa_number() = (T = Base.inferencebarrier(Number); Int(isa(3, T)) + 10 * Int(isa("a", T)) + 100 * Int(isa(2.5, T)))
sub_isa_type() = (T = Base.inferencebarrier(Type); Int(isa(Int, T)) + 10 * Int(isa(3, T)))
sub_eltype_broadcast() = (u = falses(4); @. u = eltype(SUB_ZOO) <: SUB_PETS; sum(u))

