# The `IOContext` of compiled code: streams that have properties (`:typeinfo`, `:compact`, `:limit`, `:displaysize`, ...), as the `IOContext` of Base has, which
# `show` asks for what to show and how.
#
# In Base the properties are an `ImmutableDict` of `Any`s, which the code that asks (`get(io, :compact, false)::Bool`) looks in when the program runs. Here they are
# in the *type* of the stream (`ContextIO{S,K,V}` has the names in the tuple `K`, and the values in `V`, a tuple type of `Val`s: a tuple of the values would not do, as a
# type can't be a value in a tuple that is a parameter of a type), so that asking is a constant, and what depends on it is decided
# when compiling. That is why the value of a property has to be known then (a `Bool`, a number, a type, a tuple of those): `IOContext(io, :compact => flag)` with
# a `flag` that is only known when the program runs is a call that can't be resolved (compiling says so). Properties that are not kept: `:SHOWN_SET` (the
# containers that contain themselves, which are not detected) and `:module` (the names of types are made when compiling, see `show.jl`).

"""
    ContextIO{S,K,V}

The stream `S` with the properties `K` (names) and `V` (their values, as a `Tuple` type of `Val`s) of its context, which are in the type, so that they are known when compiling.
(Made by `IOContext(io, :name => value, ...)`, as in Base.)
"""
struct ContextIO{S<:IO,K,V} <: IO
    io::S
end

Base.unsafe_write(io::ContextIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.io, p, n)
Base.write(io::ContextIO, x::UInt8) = write(io.io, x)
Base.flush(io::ContextIO) = flush(io.io)
Base.isopen(io::ContextIO) = isopen(io.io)
Base.iswritable(io::ContextIO) = iswritable(io.io)
Base.lock(::ContextIO) = nothing
Base.unlock(::ContextIO) = nothing

"""
    BufIO

The stream that `sprint` and `repr` write to when compiled: an `IOBuffer`, which is not one of the streams
that the methods of `show.jl` are for, inside a type that is.
"""
struct BufIO <: IO
    buf::IOBuffer
end
Base.unsafe_write(io::BufIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.buf, p, n)
Base.write(io::BufIO, x::UInt8) = write(io.buf, x)
Base.flush(::BufIO) = nothing
Base.isopen(io::BufIO) = isopen(io.buf)
Base.iswritable(::BufIO) = true
Base.lock(::BufIO) = nothing
Base.unlock(::BufIO) = nothing

# the streams that the methods of `show.jl` and this file are for
const ShowStream = Union{LibcStream, ContextIO, BufIO}

# the stream that is written to, without its context
base_io(io::ContextIO) = io.io
base_io(io) = io

## asking

Base.get(::ShowStream, key::Symbol, default) = default # (no properties)
# (`S<:IO` as in the type: without it the method is not as specific as one for `Union{..., ContextIO, ...}`, and is not the one that is called)
@generated function Base.get(io::ContextIO{S,K,V}, key::Symbol, default) where {S<:IO,K,V}
    body = :default
    for i in length(K):-1:1
        body = :(key === $(QuoteNode(K[i])) ? $(V.parameters[i].parameters[1]) : $body)
    end
    return body
end
@generated Base.haskey(io::ContextIO{S,K,V}, key::Symbol) where {S<:IO,K,V} = :(key in $K)
Base.getindex(io::ContextIO, key::Symbol) = haskey(io, key) ? get(io, key, nothing) : throw(KeyError(key))
Base.displaysize(io::ContextIO) = haskey(io, :displaysize) ? io[:displaysize]::Tuple{Int,Int} : displaysize(io.io)::Tuple{Int,Int}

# what the context of the stream knows about the type of what is shown: `:typeinfo`, as in Base (`Any` for no information)
typeinfo_of(io::ShowStream) = get(io, :typeinfo, Any)
# the same, from the type of the stream (for the `@generated` functions)
typeinfo_type(::Type{<:ContextIO{S,K,V}}) where {S,K,V} = (i = findfirst(==(:typeinfo), K); i === nothing ? Any : V.parameters[i].parameters[1])
typeinfo_type(::Type) = Any

## making

# the same stream with the property `key` of the value `value` (the other properties as they are)
@generated function with_property(io::S, ::Val{key}, ::Val{value}) where {S<:ShowStream, key, value}
    if S <: ContextIO
        base, K, V = S.parameters
        keys, values = Any[K...], Any[V.parameters...]
        stream = :(io.io)
    else
        base, keys, values = S, Any[], Any[]
        stream = :io
    end
    i = findfirst(==(key), keys)
    if key === :typeinfo && value === Any
        # (`Any` is what the property is when there is none: the same, and a smaller type, without a `Val{Any}`)
        i === nothing || (deleteat!(keys, i); deleteat!(values, i))
    elseif i === nothing
        push!(keys, key)
        push!(values, Val{value})
    else
        values[i] = Val{value}
    end
    isempty(keys) && return :(base_io(io))
    return :(ContextIO{$base, $(Tuple(keys)), $(Tuple{values...})}($stream))
end

# (what is not kept is not made a property: its value is not one that can be in a type, or is not used)
const IGNORED_PROPERTIES = (:SHOWN_SET, :module)
# (`@constprop :aggressive`: the name and the value of the property are known where `IOContext` is called, and have to be known in the methods, to make the type)
Base.@constprop :aggressive @inline property_context(io::ShowStream, ::Val{key}, value) where {key} = key in IGNORED_PROPERTIES ? io : with_property(io, Val(key), Val(value))

Base.@constprop :aggressive @inline Base.IOContext(io::ShowStream, p::Pair{Symbol}) = property_context(io, Val(p.first), p.second)
Base.@constprop :aggressive @inline Base.IOContext(io::ShowStream, p::Pair{Symbol}, ps::Pair{Symbol}...) = IOContext(IOContext(io, p), ps...)
# (the properties of another stream: those of the stream `context`)
Base.IOContext(io::ShowStream, ::ContextIO{S,K,V}) where {S<:IO,K,V} = ContextIO{typeof(base_io(io)),K,V}(base_io(io))
Base.IOContext(io::ShowStream, ::ShowStream) = io

# Base shows some things into a buffer first, with the context of the stream that it shows to (`IOContext(IOBuffer(), io)`, as the imaginary part of a `Complex` is):
# the buffer is written to through a `BufIO`, so that what is written to it is shown by the methods that are for those streams (and the context is static)
@device_override Base.IOContext(io::IOBuffer, context::ShowStream) = IOContext(BufIO(io), context)

typeinfo_io(io::ShowStream, ::Type{T}) where {T} = with_property(io, Val(:typeinfo), Val(T))
# the stream for the elements of `v`, which is what `show_vector` and the others of Base make with `IOContext`
@generated function elements_io(io, ::V) where {V}
    return :(typeinfo_io(io, $(eltype(V))))
end

## `sprint(f, args...)` (and `repr(x)`, which is `sprint(show, x)`) writes to a `BufIO` instead of an `IOBuffer`, with the context that the keyword `context`
## gives it: the properties of another stream (they are copied), or a `Pair` or a tuple of them

# (a method for each of the usual numbers of arguments, and not only `args...`: `args` is a tuple of the types of the arguments, and for an argument of the type `Any`
# (an element of a `Vector{Any}`, whose `alignment` is `sprint(show, x)`) it is a `Tuple{Any}`, whose layout is not known: the argument is taken out of it by a call of the
# runtime. An argument of its own is a value of the type `Any`, which is a call that is resolved over the registered types.)
for n in 0:3
    xs = [Symbol(:x, i) for i in 1:n]
    @eval @device_override Base.@constprop :aggressive @inline function Base.sprint(f::Function, $(xs...); context=nothing, sizehint::Integer=0)
        s = IOBuffer(sizehint=sizehint)
        f(sprint_context(BufIO(s), context), $(xs...))
        return Base.takestring!(s)
    end
end
@device_override Base.@constprop :aggressive @inline function Base.sprint(f::Function, args...; context=nothing, sizehint::Integer=0)
    s = IOBuffer(sizehint=sizehint)
    f(sprint_context(BufIO(s), context), args...)
    return Base.takestring!(s)
end
# (`@constprop :aggressive`: the properties are constants where `sprint` is called, and have to be known here to make the type of the stream)
sprint_context(io::BufIO, ::Nothing) = io
sprint_context(io::BufIO, ::Union{LibcStream,BufIO}) = io
sprint_context(io::BufIO, context::ContextIO) = IOContext(io, context)
Base.@constprop :aggressive @inline sprint_context(io::BufIO, context::Pair) = IOContext(io, context)
Base.@constprop :aggressive @inline sprint_context(io::BufIO, context::Tuple) = IOContext(io, context...)
