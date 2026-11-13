# Makie in a program. What Makie writes to keep Julia from compiling for each type (`@nospecializeinfer`, fields read by a number that is not known) is written again here with the types known.

module StaticRuntimeMakieExt

using StaticRuntime: @device_override
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

end # module
