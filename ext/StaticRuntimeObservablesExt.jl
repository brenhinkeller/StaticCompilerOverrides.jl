# Observables (the package that Makie, and the packages around it, build their updates on) in a program.
#
# The package keeps its listeners as `Pair{Int,Any}`, and what it calls through is written not to be specialized (`@nospecialize`, `f::Any`, `Base.invokelatest`), which keeps Julia from compiling
# it for each function and type. In a program that is the opposite of what is wanted: a call of a function that is an `Any` is a lookup in the method tables, which is the runtime that a program
# does not have (the compiler finds the functions that it can be, and makes the call over them: see "Calls of functions that are not known" in the manual, which needs no more than the call being direct).
# So the functions that call the listeners are written again, with the types known, and what only prints a listener (`methods` of it, and where it is defined) is not in the program.

module StaticRuntimeObservablesExt

using StaticRuntime: @device_override, note_callback, call_callback, add_dispatch_candidates!
using Observables: Observables, Observable, AbstractObservable, ObserverFunction, Consume, listeners, to_value, appendinputs!, pair_searchsortedlast

# `observable[] = val`: the value is converted to the type of the observable (the field is of the type `T`), and the listeners are called
@device_override function Base.setindex!(observable::Observable{T}, val) where {T}
    if observable.ignore_equal_values
        isequal(observable.val, val) && return
    end
    observable.val = convert(T, val)
    return notify(observable)
end

# What a listener is called with is the value of the observable: `register_callback` says which listeners an observable of the type `T` has, and `notify` calls those (the call is direct: `f` is
# of the type `Any`, and is one of the functions that were registered for `T`)
value_type(::AbstractObservable{T}) where {T} = T

@device_override function Observables.register_callback(observable, priority::Int, f)
    note_callback(value_type(observable), f)
    ls = listeners(observable)::Vector{Pair{Int,Any}}
    idx = pair_searchsortedlast(ls, priority)
    insert!(ls, idx + 1, Pair{Int,Any}(priority, f))
    return
end

# The listeners are called with the value, in order, until one of them returns `Consume(true)`
@device_override function Base.notify(observable::AbstractObservable{T}) where {T}
    val = observable[]
    for (_, f) in listeners(observable)::Vector{Pair{Int,Any}}
        result = call_callback(T, f, val)
        if result isa Consume && result.x
            return true
        end
    end
    return false
end

# `on`, without what is called when a listener is added (`addhandler_callbacks`, which is for tools that watch the observables)
@device_override function Observables.on(f, observable::AbstractObservable; weak::Bool = false, priority::Int = 0, update::Bool = false)::ObserverFunction
    Observables.register_callback(observable, priority, f)
    update && f(observable[])
    return ObserverFunction(f, observable, weak)
end

# A weak `ObserverFunction` removes its listener when it is collected, with a finalizer (`finalizer(off, obsfunc)` in its constructor, which does it when `weak` is not known to be
# `false` when compiling: then the program would have `off`, which finds the listener among those of the observable with a call for each of the types that it could have). A program
# that makes a connection that is weak keeps it.
@device_override Base.finalizer(::typeof(Observables.off), obsfunc::ObserverFunction) = obsfunc

# What a `map!`ed observable and an `onany` call when an observable changes, with the types of the function, the result and the arguments (the callbacks of the package have them as `Any`)
struct MapCall{F,R,A<:Tuple} <: Function
    f::F
    result::R
    args::A
end
function (c::MapCall)(_)
    c.result[] = c.f(map(to_value, c.args)...)
    return
end

struct AnyCall{F,A<:Tuple} <: Function
    f::F
    args::A
end
function (c::AnyCall)(_)
    return c.f(map(to_value, c.args)...)
end

@device_override function Base.map!(f, result::AbstractObservable, os...; update::Bool = true, priority::Int = 0)
    callback = MapCall(f, result, os)
    obsfuncs = ObserverFunction[]
    for o in os
        if o isa AbstractObservable
            push!(obsfuncs, Observables.on(callback, o; priority = priority))
        end
    end
    appendinputs!(result, obsfuncs)
    update && callback(nothing)
    return result
end

@device_override function Observables.onany(f, args...; weak::Bool = false, priority::Int = 0, update::Bool = false)
    callback = AnyCall(f, args)
    obsfuncs = ObserverFunction[]
    for observable in args
        if observable isa AbstractObservable
            push!(obsfuncs, Observables.on(callback, observable; weak = weak, priority = priority))
        end
    end
    update && callback(nothing)
    return obsfuncs
end

# (what a listener is shown as is its type: the package asks for where it is defined)
@device_override Observables.show_callback(io::IO, f, arg_types) = show(io, f)
@device_override Base.show(io::IO, obsf::ObserverFunction) = print(io, "ObserverFunction")

# A value of the type `Any` (what a `Dict{Symbol,Any}` of attributes holds) is an `Observable{Any}` when the package is used for that: a call on it is made over this type too
function __init__()
    add_dispatch_candidates!(Observable{Any})
end

end # module
