# `Dict(:a => 1, :b => "x")`: a `Dict` made of pairs of different types.
#
# Base makes it by going through the pairs as a tuple (`grow_to!`), starting with a `Dict` of the types of the first, and, when a pair does not fit, making a
# `Dict` of the types that are the `promote_typejoin` of those that it has and those of the pair, and moving what it has to it. That is a computation with
# types that Julia does when the program runs (`typejoin` of types that are not known when compiling, when the types of the values are a `Union`), which
# is not there. The types of the pairs are known when compiling, so here the same steps are followed with them, in a generated function, each one a
# statement with the types it has. What is made is the same as in Base: the same `Dict` type, and the same keys in the same table (the order of
# iteration depends on how large the table is, which depends on how it was made: `sizehint!` for pairs of one type, as `Dict{K,V}(ps)` does, and growing for
# the others, as `grow_to!` does).

@generated function static_dict_pairs(ps::P) where {P<:Tuple}
    n = isconcretetype(P) ? fieldcount(P) : -1
    n == 0 && return :(Dict{Any,Any}())
    types = n > 0 ? Any[fieldtype(P, i) for i in 1:n] : Any[]
    # (pairs whose types of key and value are not concrete have the types of what they hold only when the program runs: Base's way)
    ok = 1 <= n <= 64 && all(T -> T isa DataType && T <: Pair && isconcretetype(T), types)
    ok || return :(Dict(ps))
    keytypes = Any[T.parameters[1] for T in types]
    valuetypes = Any[T.parameters[2] for T in types]
    statements = Expr[]
    if all(T -> T === types[1], types)
        # `Dict{K,V}(ps)`: one table of the size that is for `n` pairs
        K, V = keytypes[1], valuetypes[1]
        push!(statements, :(d1 = Dict{$K,$V}()), :(sizehint!(d1, $n)))
        for i in 1:n
            push!(statements, :(d1[ps[$i].first] = ps[$i].second))
        end
        return Expr(:block, statements..., :d1)
    end
    # `grow_to!`: a `Dict` of the types of the first pair, which is widened when a pair does not fit
    current = 1
    K, V = keytypes[1], valuetypes[1]
    push!(statements, :(d1 = Dict{$K,$V}()), :(d1[ps[1].first] = ps[1].second))
    for i in 2:n
        dest, next = Symbol(:d, current), Symbol(:d, current + 1)
        if keytypes[i] <: K && valuetypes[i] <: V
            push!(statements, :($dest[ps[$i].first] = ps[$i].second))
        else
            K, V = Base.promote_typejoin(K, keytypes[i]), Base.promote_typejoin(V, valuetypes[i])
            push!(statements, :($next = Dict{$K,$V}()), :(merge!($next, $dest)), :($next[ps[$i].first] = ps[$i].second))
            current += 1
        end
    end
    return Expr(:block, statements..., Symbol(:d, current))
end

@device_override Base.Dict(ps::Pair...) = static_dict_pairs(ps)
