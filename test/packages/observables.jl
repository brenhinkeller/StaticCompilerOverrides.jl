# Observables: values that call functions when they are set (`on`, `map`, `onany`), which Makie is built on. The package calls its listeners as functions of the type `Any` (see
# `ext/StaticRuntimeObservablesExt.jl`).

using Observables, StaticArrays

@testset "Observables" begin
    check_cases([
        "set and get"  => () -> (o = Observable(opaque(1)); o[] = 5; o[] + 1),
        "on"           => () -> (o = Observable(opaque(1)); n = Ref(0); on(x -> n[] += x, o); o[] = 4; n[]),
        "on, twice"    => () -> (o = Observable(opaque(1)); n = Ref(0); on(x -> n[] += x, o); on(x -> n[] += 10x, o); o[] = 4; n[]),
        "on, weak not known" => () -> (o = Observable(opaque(1)); n = Ref(0); on(x -> n[] += x, o; weak = opaque(1) > 5); o[] = 4; n[]),
        "update"       => () -> (o = Observable(opaque(3)); n = Ref(0); on(x -> n[] += x, o; update = true); n[]),
        "map"          => () -> (o = Observable(opaque(2)); m = map(x -> x * 3, o); o[] = 5; m[]),
        "map, two"     => () -> (a = Observable(opaque(1)); b = Observable(opaque(2)); m = map((x, y) -> x + y, a, b); a[] = 10; m[]),
        "onany"        => () -> (a = Observable(opaque(1)); b = Observable(opaque(2)); n = Ref(0); onany((x, y) -> n[] += x * y, a, b); a[] = 4; n[]),
        "a Float64"    => () -> (o = Observable(Float64(opaque(1))); n = Ref(0.0); on(v -> n[] += v, o); o[] = 3.0; round(Int, n[])),
        "an SVector"   => () -> (o = Observable(SVector(opaque(1), 2)); n = Ref(0); on(v -> n[] += v[1], o); o[] = SVector(3, 4); n[]),
        "no listener"  => () -> (o = Observable(SVector(opaque(1), 2)); o[] = SVector(3, 4); o[][1]),
        "two types"    => () -> (a = Observable(opaque(1)); b = Observable(2.5); n = Ref(0.0); on(x -> n[] += x, a); on(y -> n[] += 10y, b); a[] = 4; b[] = 1.5; round(Int, n[])),
        "a tuple"      => () -> (o = Observable((opaque(1), 2)); n = Ref(0); on(v -> n[] += v[1], o); o[] = (3, 4); n[]),
    ])
end
