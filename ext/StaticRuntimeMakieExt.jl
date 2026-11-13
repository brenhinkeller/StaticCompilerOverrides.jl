# Makie in a program. What Makie writes to keep Julia from compiling for each type (`@nospecializeinfer`, fields read by a number that is not known) is written again here with the types known.

module StaticRuntimeMakieExt

using StaticRuntime: @device_override, add_dispatch_candidates!
using Makie: Makie, node_any, value_convert

# The attributes of a call (`Attributes(color = :red, linewidth = 2)`): a `Dict` of the observables of the values. The fields of the `NamedTuple` are visited by `map`, which is
# unrolled when compiling (the package reads each by its number, with a function that is not inferred)
@device_override function Makie.node_pairs(nt::NamedTuple)
    d = Dict{Symbol,Any}()
    map(keys(nt), values(nt)) do k, v
        d[k] = node_any(value_convert(v))
    end
    return d
end

@device_override function Makie.node_pairs(pairs)
    d = Dict{Symbol,Any}()
    for (k, v) in pairs
        d[k] = node_any(value_convert(v))
    end
    return d
end

# The pairs of the attributes: the value is of any type, and `Pair(key, value)` takes the type of the pair from the type of the value
@device_override function Base.iterate(x::Makie.Attributes, state...)
    s = iterate(keys(x), state...)
    s === nothing && return nothing
    return (Pair{Symbol,Any}(s[1], x[s[1]]), s[2])
end

# The defaults of the `SSAO` are the attributes of the theme, with values of the types of its fields. The theme for a key may be given as anything (`theme` is inferred as a union with `Nothing`, `Observable` and `NamedTuple`), and the call of the constructor
# with each of them is not one that can be split
@device_override function Makie.SSAO(; radius = nothing, bias = nothing, blur = nothing)
    defaults = Makie.theme(nothing, :SSAO)::Makie.Attributes
    _radius = isnothing(radius) ? defaults.radius[]::Float32 : radius
    _bias = isnothing(bias) ? defaults.bias[]::Float32 : bias
    _blur = isnothing(blur) ? defaults.blur[]::Int32 : blur
    return Makie.SSAO(_radius, _bias, _blur)
end

# The finalizer of a root `Scene` frees what the screens of a backend hold, in a task (`@async`), and logs what goes wrong: there are no tasks, and no screens that are not
# closed by the program
@device_override Base.finalizer(f, scene::Makie.Scene) = scene

# The values of the attributes are of any type: these are the ones that they have in the theme (the colors and vectors of the lights, the nested `Attributes`)
function __init__()
    add_dispatch_candidates!(Makie.Attributes, Makie.RGBf, Makie.Vec3f, Tuple{Int,Int})
    return nothing
end

end # module
