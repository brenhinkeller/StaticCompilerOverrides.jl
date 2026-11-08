# `show` of types and containers.
#
# Base's `show` for a container asks the `IOContext` of the stream what the type of the elements already
# is (`:typeinfo`, a `Type` in an `ImmutableDict` of `Any`s), and prints type names by looking at modules and
# bindings. That is all dynamic. Here both are known when compiling:
#
# * the name of a type `T` is a constant string, made by Base's own `show` when compiling, so that it is
#   exactly what Base prints;
# * what the context knows about the type of the elements is in the type of the stream: a
#   [`TypeInfoIO{T}`](@ref) holds the stream that is written to, and `T` is in its type.
#
# What Base does with the two (`typeinfo_prefix`) is done when compiling, for the type of the container.

"""
    TypeInfoIO{T,S}

The stream that `show` of a container passes on to show its elements: it writes to the stream `S`, and has
the `:typeinfo` of its context, `T`, in its type (so that it is known when compiling).
"""
struct TypeInfoIO{T,S<:IO} <: IO
    io::S
end
TypeInfoIO{T}(io::S) where {T,S<:IO} = TypeInfoIO{T,S}(io)

Base.unsafe_write(io::TypeInfoIO, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.io, p, n)
Base.write(io::TypeInfoIO, x::UInt8) = write(io.io, x)
Base.flush(io::TypeInfoIO) = flush(io.io)
Base.isopen(io::TypeInfoIO) = isopen(io.io)
Base.iswritable(io::TypeInfoIO) = iswritable(io.io)
Base.lock(::TypeInfoIO) = nothing
Base.unlock(::TypeInfoIO) = nothing

"""
    BufIO

The stream that `sprint` and `repr` write to when compiled: an `IOBuffer`, which is not one of the streams
that the methods of this file are for, inside a type that is.
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

# `sprint(f, args...)` (and `repr(x)`, which is `sprint(show, x)`) writes to a `BufIO` instead of an `IOBuffer`. What the
# `context` keyword of Base does (an `IOContext` for what is shown) is not kept for `nothing` or a stream of
# this file; any other (a `Pair`, a tuple of them, an `IOContext`) is passed on to Base's method
@device_override function Base.sprint(f::Function, args...; context=nothing, sizehint::Integer=0)
    s = IOBuffer(sizehint=sizehint)
    if context === nothing || context isa Union{LibcStream, TypeInfoIO, BufIO}
        f(BufIO(s), args...)
    elseif context isa Tuple
        f(IOContext(s, context...), args...)
    else
        f(IOContext(s, context), args...)
    end
    return Base.takestring!(s)
end

# the streams that the methods below are for
const ShowStream = Union{LibcStream, TypeInfoIO, BufIO}

# what the context of the stream knows about the type of what is shown: `:typeinfo`, as in Base (`Any` for
# no information). When the key is known (it is, when compiling) this is a constant.
Base.get(::ShowStream, key::Symbol, default) = default
Base.get(::TypeInfoIO{T}, key::Symbol, default) where {T} = key === :typeinfo ? T : default

typeinfo_of(::ShowStream) = Any
typeinfo_of(::TypeInfoIO{T}) where {T} = T
# the same, from the type of the stream (for the `@generated` functions)
typeinfo_type(::Type{<:TypeInfoIO{T}}) where {T} = T
typeinfo_type(::Type) = Any

# the stream that is written to, and the stream for the elements of `v`, which is what `show_vector` and the
# others of Base make with `IOContext`
base_io(io::TypeInfoIO) = base_io(io.io)
base_io(io) = io
@generated function elements_io(io, ::V) where {V}
    return :(TypeInfoIO{$(eltype(V))}(base_io(io)))
end

# The rest of what is in an `IOContext` of Base (`:SHOWN_SET` for the containers that contain themselves,
# `:compact`, `:limit`, ...) is not kept: what is shown is not cut, and has no cycles of containers
Base.IOContext(io::ShowStream, ::Pair) = io
Base.IOContext(io::ShowStream, ::Pair, ::Pair...) = io
Base.show_circular(::ShowStream, @nospecialize(x)) = false

## names of types

# The text that Base's `show` makes for what is shown to a stream (as `stdout`, for which the types of `Main` are
# not written with their module), made when compiling by the `@generated` functions below. A generator runs in
# the world age of its definition, in which what the program defines (its types in `Main`, ...) is not visible, so
# Base's `show` writes `Main.Pt` where it writes `Pt` for the program; the `Main.` is dropped. (Types of other modules that
# the program makes visible with `using` or `import` do get their module: a difference with Base.)
host_string(f, x) = replace(sprint(f, x; context = :module => Main), r"(?<![\w.])Main\." => "")

@generated type_name(::Type{T}) where {T} = host_string(show, T)
Base.show(io::ShowStream, ::Type{T}) where {T} = (print(io, type_name(T)); nothing)

## `typeinfo_prefix` of Base, which prefixes what is shown by the type of the container when the context
## doesn't know the type of the elements. It depends on the types only, and on whether the container is empty.

# `_typeinfo_implicit` of Base finds the method in the latest world: dynamic. The answer depends on the
# type only
@generated function static_implicit(::Type{T}) where {T}
    return Base.typeinfo_implicit(T)
end
@device_override Base._typeinfo_implicit(::Type{T}) where {T} = static_implicit(T)

@generated function typeinfo_prefix_static(::Type{TI}, X::XT) where {TI,XT}
    typeinfo = XT <: TI ? TI : Any
    eltype_ctx = Base.typeinfo_eltype(typeinfo)
    eltype_X = eltype(XT)
    # the strings that Base makes, for the container being empty and not
    if XT <: AbstractDict
        full = host_string(print, XT)
        name = host_string(Base.show_type_name, XT.name)
        if eltype_X == eltype_ctx
            return :(($name, false))
        else
            implicit = Base._typeinfo_implicit(keytype(XT)) && Base._typeinfo_implicit(valtype(XT))
            return implicit ? :(isempty(X) ? ($full, false) : ($name, true)) : :(($full, false))
        end
    elseif eltype_X == eltype_ctx
        return :(("", false))
    else
        implicit = Base.typeinfo_implicit(eltype_X)
        text = Base.print_without_params(eltype_X) ?
            host_string(Base.show_type_name, Base.unwrap_unionall(eltype_X).name) : host_string(print, eltype_X)
        return implicit ? :(isempty(X) ? ($text, false) : ("", true)) : :(($text, false))
    end
end
Base.typeinfo_prefix(io::ShowStream, X) = typeinfo_prefix_static(typeinfo_of(io), X)

## `Symbol`s

# Base decides whether a `Symbol` prints as `:name` with the tables of the parser (`isidentifier`, `isoperator`,
# ...), which are in libjulia. The names that are plain ASCII identifiers print as `:name` in Base and here;
# for any other it's an error, as printing it differently from Base would be wrong
function Base.show(io::ShowStream, s::Symbol)
    n = ncodeunits(string(s))
    str = string(s)
    ok = n > 0
    i = 1
    while ok && i <= n
        c = codeunit(str, i)
        isalpha = (UInt8('a') <= c <= UInt8('z')) || (UInt8('A') <= c <= UInt8('Z')) || c == UInt8('_')
        isother = (UInt8('0') <= c <= UInt8('9')) || c == UInt8('!')
        ok = isalpha || (i > 1 && isother)
        i += 1
    end
    ok || error("show: a Symbol that is not an ASCII identifier is not supported")
    print(io, ':', str)
    return nothing
end

## elements of an abstract type: dispatch over a closed set of types
##
## `show(io, x)` of an `x` of the type `Any` (an element of a `Vector{Any}`) is a dynamic call in Julia. When
## compiling, only a closed set of the types is known to be possible, and the call is a chain of `isa`
## (tests of the type tag of `x`) over that set. What is not in the set is not known, which strict
## mode cannot report, so what is not in the set is an error when the program runs. Add types with
## `add_show_candidates!`.

const DEFAULT_SHOW_CANDIDATES = Type[Int, Float64, String, Bool, Char, Symbol, Nothing,
    Int8, Int16, Int32, Int64, Int128, UInt8, UInt16, UInt32, UInt64, UInt128, Float16, Float32,
    Missing, Vector{Any}]

const SHOW_CANDIDATES = Type[]

"""
    add_show_candidates!(types...)

Add concrete types to the ones, besides the usual (numbers, `String`, `Char`, `Symbol`, `Nothing`, `Missing`,
`Vector{Any}`), that `show` of a value of an abstract type (an element of a `Vector{Any}`, say) dispatches over in
compiled code, for example `add_show_candidates!(MyType, Tuple{Int,Float64})`. A value of another type is an
error when the program runs. Call it before compiling the code that shows such values (the code that is
compiled is the one that has been made from the types at that time).

(It is a list, not a method that you add, because the code that makes the dispatch runs in the world age
of `show_element`, where the methods that you define later are not visible.)
"""
function add_show_candidates!(types::Type...)
    for T in types
        isconcretetype(T) || throw(ArgumentError("$T is not a concrete type"))
        if !(T in SHOW_CANDIDATES)
            push!(SHOW_CANDIDATES, T)
            CANDIDATES_VERSION[] += 1
        end
    end
    return nothing
end

@generated function show_element(io, x, ::Type{T}) where {T}
    isconcretetype(T) && return :(show(io, x); nothing)
    body = Expr(:block)
    for C in vcat(DEFAULT_SHOW_CANDIDATES, SHOW_CANDIDATES)
        typeintersect(C, T) === Union{} && continue
        # (an `isa` that is true when `T` is a subtype of `C`: no test)
        push!(body.args, :(x isa $C && return (show(io, x::$C); nothing)))
    end
    push!(body.args, :(error("show: a value of a type that is not in the list of `add_show_candidates!`")))
    return body
end

## the containers: what Base does, without the `IOContext`

function Base.show_vector(io::ShowStream, v, opn='[', cls=']')
    prefix, implicit = Base.typeinfo_prefix(io, v)
    print(io, prefix)
    # (two calls, so that the type of the stream is known in each)
    if implicit
        Base.show_delim_array(io, v, opn, ",", cls, false)
    else
        Base.show_delim_array(elements_io(io, v), v, opn, ",", cls, false)
    end
    return nothing
end

function Base.show_delim_array(io::ShowStream, itr::Union{AbstractArray,Core.SimpleVector}, op, delim, cl,
                               delim_one, i1=first(LinearIndices(itr)), l=last(LinearIndices(itr)))
    print(io, op)
    first = true
    i = i1
    if l >= i1
        while true
            if !isassigned(itr, i)
                print(io, Base.undef_ref_str)
            else
                show_element(io, itr[i], eltype(itr))
            end
            if i == l
                delim_one && first && print(io, delim)
                break
            end
            i += 1
            first = false
            print(io, delim)
            print(io, ' ')
        end
    end
    print(io, cl)
end

# any other iterable (the elements of a `Set`...): each element is shown with the type of the elements
function Base.show_delim_array(io::ShowStream, itr, op, delim, cl, delim_one, i1=1, n=typemax(Int))
    print(io, op)
    first = true
    i = 0
    for x in itr
        i += 1
        i < i1 && continue
        first || (print(io, delim); print(io, ' '))
        first = false
        show_element(io, x, eltype(itr))
        i1 + i - i1 + 1 > n && break # (`n` is the number of elements, from `i1`)
    end
    delim_one && !first && i - i1 == 0 && print(io, delim)
    print(io, cl)
end

# `Dict(k => v, ...)`, and the other dictionaries, as `show` for them in Base, with the pairs shown with the type of the
# pairs of the dictionary
function Base.show(io::ShowStream, t::AbstractDict)
    print(io, Base.typeinfo_prefix(io, t)[1])
    print(io, '(')
    if !isempty(t)
        eio = elements_io(io, t)
        first = true
        for pair in t
            first || print(io, ", ")
            first = false
            show_element(eio, pair, eltype(t))
        end
    end
    print(io, ')')
    return nothing
end

# `Set([...])` (compare with `show` for a `Set` in Base: `==` of types is a call of libjulia, `===` is the same here)
function Base.show(io::ShowStream, s::Set)
    if isempty(s)
        if typeinfo_of(io) === typeof(s)
            print(io, "Set()")
        else
            show(io, typeof(s))
            print(io, "()")
        end
    else
        print(io, "Set(")
        Base.show_vector(io, s)
        print(io, ')')
    end
    return nothing
end

# the elements of a tuple, each with the type that the tuple has for it
@generated function Base.show(io::ShowStream, t::T) where {T<:Tuple}
    TI = typeinfo_type(io)
    n = fieldcount(T)
    body = Expr(:block, :(print(io, '(')))
    for i in 1:n
        i > 1 && push!(body.args, :(print(io, ", ")))
        typeinfo = (T <: TI && TI <: Tuple && fieldcount(TI) >= i) ? fieldtype(TI, i) : TI
        push!(body.args, :(show_element(TypeInfoIO{$typeinfo}(base_io(io)), t[$i], $(fieldtype(T, i)))))
    end
    n == 1 && push!(body.args, :(print(io, ',')))
    push!(body.args, :(print(io, ')')), :(nothing))
    return body
end

## `Pair`: `a => b`, or `Pair{K,V}(a, b)` when the context doesn't make the types clear (as in Base: see `show` for
## a `Pair` there), with each of the parts shown with the type that the pair has for it

@generated function Base.show(io::ShowStream, p::P) where {P<:Pair}
    isconcretetype(P) || return :(error("show: the type of a pair is not known when compiling"))
    K, V = P.parameters
    TI = typeinfo_type(io)
    # a pair is `delimited` (shown with its type) if it isn't of the types of its parts, and the context doesn't have its type
    # (`has_tight_type` of Base compares types with `==`, which is a call of libjulia: `===` is the same for these)
    tight = isconcretetype(K) && isconcretetype(V) ? true : :(typeof(p.first) === $K && typeof(p.second) === $V)
    delimited = (tight === true || TI == P) ? false : :(!$tight)
    infos = (P <: TI && TI <: Pair) ? (fieldtype(TI, 1), fieldtype(TI, 2)) : (Any, Any)
    parts = Expr(:block)
    for (i, (name, T)) in enumerate(((:first, K), (:second, V)))
        # (a part of an abstract type is not known to be a pair, and is delimited)
        isdelimited = isconcretetype(T) ? :(Base.isdelimited(io_i, x)) : true
        push!(parts.args, quote
            io_i = TypeInfoIO{$(infos[i])}(base_io(io))
            x = p.$name
            d = $isdelimited
            d || print(io, "(")
            show_element(io_i, x, $T)
            d || print(io, ")")
            $(i == 1 ? :(print(io, " => ")) : :nothing)
        end)
    end
    return quote
        if $delimited
            Base.show_pairtyped(io, p)
        else
            $parts
        end
        nothing
    end
end

## structs: `show_default` of Base, `Name(field, field, ...)`, with the type name and the types of the fields known
## when compiling (a field of an abstract type is shown with `show_element`)

@generated function Base.show_default(io::ShowStream, x::T) where {T}
    isconcretetype(T) || return :(error("show: the type of a value is not known when compiling"))
    isprimitivetype(T) && return :(error("show: a primitive type needs a method of `show`"))
    body = Expr(:block, :(print(io, $(host_string(show, T)), '(')))
    n = fieldcount(T)
    for i in 1:n
        i > 1 && push!(body.args, :(print(io, ", ")))
        push!(body.args, :(if isdefined(x, $i)
            show_element(TypeInfoIO{Any}(base_io(io)), getfield(x, $i), $(fieldtype(T, i)))
        else
            print(io, Base.undef_ref_str)
        end))
    end
    push!(body.args, :(print(io, ')')), :(nothing))
    return body
end
