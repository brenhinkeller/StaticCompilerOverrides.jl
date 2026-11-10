# OrderedCollections.jl: dictionaries and sets that keep the order of insertion, `LittleDict` (for a few keys), and what is done with them.
using OrderedCollections

@testset "OrderedCollections.jl" begin
    check_cases([
        "OrderedDict"           => @opaque(() -> (d = OrderedDict{Int,Int}(); d[3] = 1; d[1] = 2; d[2] = 3; sum(k * 10^i for (i, k) in enumerate(keys(d))))),
        "delete!"               => @opaque(() -> (d = OrderedDict(i => i * i for i in 1:10); delete!(d, 3); delete!(d, 7); length(d) * 1000 + sum(values(d)))),
        "String keys"           => @opaque(() -> (d = OrderedDict{String,Int}(); d[string("b", 1)] = 1; d["a"] = 2; first(keys(d))[1] == 'b' ? length(d) : -1)),
        "iteration order"       => @opaque(() -> (d = OrderedDict(:z => 1, :a => 2, :m => 3); s = 0; for (k, v) in d; s = s * 10 + v; end; s)),
        "merge"                 => @opaque(() -> (c = merge(OrderedDict(1 => 2), OrderedDict(3 => 4)); sum(collect(keys(c))))),
        "sort"                  => @opaque(() -> (e = sort(OrderedDict(3 => 1, 1 => 2, 2 => 3)); sum(k * 10^i for (i, k) in enumerate(keys(e))))),
        "pop!, popfirst!"       => @opaque(() -> (d = OrderedDict(1 => 2, 3 => 4, 5 => 6); a = pop!(d); b = popfirst!(d); a[2] * 10 + b[2] + length(d))),
        "get!, haskey"          => @opaque(() -> (d = OrderedDict{Int,Int}(); get!(d, 1, 5); get!(d, 1, 9) + Int(haskey(d, 1)) + length(d))),
        "many keys, many deleted" => @opaque(() -> (d = OrderedDict{Int,Int}(); for i in 1:1000; d[i] = i; end; for i in 1:2:1000; delete!(d, i); end; sum(values(d)) + length(d))),
        "OrderedSet"            => @opaque(() -> (s = OrderedSet{Int}(); for i in (3, 1, 3, 2); push!(s, i); end; sum(x * 10^i for (i, x) in enumerate(s)))),
        "OrderedSet operations" => @opaque(() -> (a = OrderedSet([1, 2, 3]); b = OrderedSet([3, 4]); length(union(a, b)) * 10 + length(intersect(a, b)))),
        "LittleDict"            => @opaque(() -> (d = LittleDict{Symbol,Int}(:a => 1, :b => 2); d[:b] * 10 + d[:a])),
    ])
end
