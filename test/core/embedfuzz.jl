# Differential test of the objects that are copied into the binary: random nested values (strings, symbols, numbers of all sizes, vectors
# and matrices, tuples, named tuples, dictionaries, sets, ranges, pairs, `Ref`s, structs with other structs and containers in them) are the
# constants of a program that computes a number from all that is in them (a `digest`), and the binary has to print what Julia computes.

module EmbedFuzz
    using Random

    struct Leaf{T}; a::T; b::String; end
    struct Branch{A,B}; left::A; right::B; tag::Symbol; end
    mutable struct Cell{T}; value::T; name::String; end
    struct WithOptional; x::Union{Nothing,Int}; y::Union{Nothing,Vector{Float64}}; end

    # the value of what is in it (the same in the binary as in Julia: only integers are added, and what is added is the same in any order)
    digest(x::Bool) = Int(x) + 1
    digest(x::Union{Int8,Int16,Int32,Int64,UInt8,UInt16,UInt32,UInt64}) = Int(x % Int32) + 3
    digest(x::Union{Float32,Float64}) = round(Int, 1000 * x) + 5
    digest(x::Char) = Int(UInt32(x)) + 7
    function digest(x::AbstractString)
        s = 11
        for i in 1:ncodeunits(x)
            s += Int(codeunit(x, i))
        end
        return s
    end
    digest(x::Symbol) = digest(string(x)) + 13
    digest(::Nothing) = 17
    digest(x::Tuple) = foldl((acc, e) -> 31 * acc + digest(e), x; init = 19)
    digest(x::NamedTuple) = digest(values(x)) + 23
    # (for an array of objects, how many are the first one: the objects are one each, as in Julia)
    shared(x::AbstractArray) = isbitstype(eltype(x)) || isempty(x) ? 0 : count(e -> e === first(x), x)
    digest(x::AbstractArray) = foldl((acc, e) -> 31 * acc + digest(e), x; init = 29 + length(x)) + 100 * ndims(x) + 1000 * shared(x)
    digest(x::AbstractRange) = length(x) * 37 + digest(first(x)) + digest(last(x))
    digest(x::Pair) = digest(x.first) * 3 + digest(x.second)
    digest(x::Dict) = sum(p -> digest(p.first) * 3 + digest(p.second), x; init = 41)
    digest(x::Set) = sum(digest, x; init = 43)
    digest(x::Ref) = digest(x[]) + 47
    digest(x::BitArray) = sum(Int, x; init = 53) + length(x)
    digest(x::Union{Leaf,Branch,Cell,WithOptional}) = digest_fields(x)
    @generated function digest_fields(x::T) where {T}
        terms = [:(digest(getfield(x, $i))) for i in 1:fieldcount(T)]
        return :(59 + 7 * $(fieldcount(T)) + $(Expr(:call, :+, 0, terms...)))
    end

    # what a program does to a copy of its constants: grows the containers that it can (the copy is on the heap, as what the program makes)
    grow!(x) = x
    grow!(x::Vector{Int}) = (push!(x, 7); x)
    grow!(x::Vector{Float64}) = (push!(x, 0.5); x)
    grow!(x::Dict{String,Int}) = (x["zz"] = 5; x)
    grow!(x::Set{Int}) = (push!(x, 99); x)
    grow!(x::Cell{Int}) = (x.value += 1; x)
    grow!(x::Tuple) = (grow_each!(x...); x)
    grow_each!() = nothing
    grow_each!(y, ys...) = (grow!(y); grow_each!(ys...))
    @generated function grow!(x::Union{Leaf,Branch})
        return Expr(:block, [:(grow!(getfield(x, $i))) for i in 1:fieldcount(x)]..., :(x))
    end
    grow!(x::Cell) = (grow!(x.value); x)

    ## random values

    leaf(rng) = rand(rng, (
        () -> rand(rng, -1000:1000), () -> rand(rng, Int8), () -> rand(rng, UInt16), () -> rand(rng, UInt64) % UInt32, () -> rand(rng, Bool),
        () -> round(rand(rng) * 100, digits = 3), () -> Float32(round(rand(rng) * 10, digits = 2)), () -> rand(rng, 'a':'z'),
        () -> randstring(rng, rand(rng, 0:12)), () -> Symbol(randstring(rng, 'a':'z', rand(rng, 1:6))), () -> nothing))()

    function container(rng, depth)
        T = rand(rng, 1:19)
        n = rand(rng, 0:5)
        T == 1 && return [rand(rng, -50:50) for _ in 1:n]
        T == 2 && return [round(rand(rng) * 10, digits = 2) for _ in 1:n]
        T == 3 && return [randstring(rng, rand(rng, 0:6)) for _ in 1:n]
        T == 4 && return Tuple(value(rng, depth - 1) for _ in 1:rand(rng, 1:4))
        T == 5 && return (; (Symbol("f", i) => value(rng, depth - 1) for i in 1:rand(rng, 1:3))...)
        T == 6 && return Dict(randstring(rng, 3) => rand(rng, 1:100) for _ in 1:n)
        T == 7 && return Dict(Symbol(randstring(rng, 'a':'z', 3)) => rand(rng) for _ in 1:n)
        T == 8 && return Set(rand(rng, 1:30) for _ in 1:n)
        T == 9 && return rand(rng, 0:3, rand(rng, 1:3), rand(rng, 1:3)) .* 0.5
        T == 10 && return rand(rng, (1:rand(rng, 0:9), 0.5:0.5:rand(rng, 1:3), range(0, 1, length = rand(rng, 2:6))))
        T == 11 && return rand(rng, -9:9) => value(rng, depth - 1)
        T == 12 && return Ref(value(rng, depth - 1))
        T == 13 && return BitVector(rand(rng, Bool, n))
        T == 15 && return Union{Nothing,Int}[rand(rng, Bool) ? nothing : rand(rng, 1:9) for _ in 1:n]
        T == 16 && return [(rand(rng, 1:9), randstring(rng, 2)) for _ in 1:n]
        T == 17 && return [randstring(rng, 2) for _ in 1:rand(rng, 1:3), _ in 1:rand(rng, 1:3)]
        T == 18 && return Dict(randstring(rng, 2) => [rand(rng, 1:9) for _ in 1:rand(rng, 0:3)] for _ in 1:n)
        T == 19 && (c = Cell(rand(rng, 1:9), randstring(rng, 2)); return [c for _ in 1:rand(rng, 1:4)])
        return [container(rng, depth - 1) for _ in 1:rand(rng, 0:3)] |> v -> isempty(v) ? Int[] : [first(v) for _ in v]
    end

    function structure(rng, depth)
        T = rand(rng, 1:4)
        T == 1 && return Leaf(value(rng, depth - 1), randstring(rng, rand(rng, 0:4)))
        T == 2 && return Branch(value(rng, depth - 1), value(rng, depth - 1), Symbol(randstring(rng, 'a':'z', 4)))
        T == 3 && return Cell(value(rng, depth - 1), randstring(rng, 3))
        return WithOptional(rand(rng, Bool) ? nothing : rand(rng, 1:9), rand(rng, Bool) ? nothing : rand(rng, 3))
    end

    function value(rng, depth)
        depth <= 0 && return leaf(rng)
        r = rand(rng)
        r < 0.25 && return leaf(rng)
        r < 0.7 && return container(rng, depth)
        return structure(rng, depth)
    end
end

@testset "Embedding: random values as constants" begin
    for seed in 1:30
        rng = Random.Xoshiro(seed)
        v = EmbedFuzz.value(rng, 3)
        f = () -> EmbedFuzz.digest(v)
        status, detail = static_status(f)
        # and a copy of it that the program changes (the constant is not: what is changed is what the program has made)
        g = () -> (w = deepcopy(v); EmbedFuzz.grow!(w); EmbedFuzz.digest(w))
        status2, detail2 = static_status(g)
        @test (status2, detail2) == (:ok, "") || (@info "embedding fuzz case (a copy that is changed)" seed typeof(v) first(replace(string(detail2), '\n' => ' '), 400); false)
        @test (status, detail) == (:ok, "") || (@info "embedding fuzz case" seed typeof(v) first(replace(string(detail), '\n' => ' '), 400); false)
    end
end
