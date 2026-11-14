# Makie in a program (Makie 0.23: the version before the compute graph of 0.24, which resolves its edges with types and names that it makes when the program runs). What Makie writes to keep Julia from
# compiling for each type, or in a way that the types of the values are lost, is written again here with the types known.

module StaticRuntimeMakieExt

using StaticRuntime: @device_override, add_dispatch_candidates!
using Makie: Makie, Scene, SSAO, Attributes

# The finalizer of a `Scene` frees what the screens of a backend hold: there are no screens that the program has not closed
@device_override Base.finalizer(f::Function, scene::Scene) = scene

# The pairs of the attributes: the value is of any type, and `Pair(key, value)` takes the type of the pair from the type of the value
@device_override function Base.iterate(x::Attributes, state...)
    s = iterate(keys(x), state...)
    s === nothing && return nothing
    return (Pair{Symbol,Any}(s[1], x[s[1]]), s[2])
end

# The defaults of the `SSAO` are the attributes of the theme, with values of the types of its fields. The theme for a key may be given as anything (`theme` is inferred as a union with `Nothing`,
# `Observable` and `NamedTuple`), and the call of the constructor with each of them is not one that can be split
@device_override function Makie.SSAO(; radius = nothing, bias = nothing, blur = nothing)
    defaults = Makie.theme(nothing, :SSAO)::Attributes
    _radius = isnothing(radius) ? defaults.radius[]::Float32 : radius
    _bias = isnothing(bias) ? defaults.bias[]::Float32 : bias
    _blur = isnothing(blur) ? defaults.blur[]::Int32 : blur
    return SSAO(_radius, _bias, _blur)
end

# The default gaps of a `GridLayout` are those of the theme: GridLayoutBase calls a function that Makie keeps in a `Ref` (`DEFAULT_COLGAP_GETTER[]()`, set when Makie is loaded), and the call of a function
# that is stored where its type is lost is the call of any function. The functions that are stored are these, with the same result
# (`theme(key; default)` is a union of types, `Nothing`, `Attributes`, `Observable` and an abstract `NamedTuple`, so the theme is read here: what it gives for a key that is in it)
function theme_gap(key::Symbol, default::Float64)
    t = Makie.current_default_theme()
    haskey(t, key) || return default
    return convert(Float64, Makie.to_value(t[key])::Real)
end
@device_override Makie.GridLayoutBase.get_default_colgap()::Float64 = theme_gap(:colgap, Float64(Makie.GridLayoutBase.DEFAULT_COLGAP[]))
@device_override Makie.GridLayoutBase.get_default_rowgap()::Float64 = theme_gap(:rowgap, Float64(Makie.GridLayoutBase.DEFAULT_ROWGAP[]))

# The values of the attributes are of any type: these are the ones that they have in the theme (the colors and vectors of the lights, the nested `Attributes`, the size)
function __init__()
    add_dispatch_candidates!(Attributes, Makie.RGBf, Makie.Vec3f, Tuple{Int,Int})
    return nothing
end

end # module
