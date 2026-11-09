# `show` of types and containers.
#
# Base's `show` for a container asks the `IOContext` of the stream what the type of the elements already
# is (`:typeinfo`), and prints type names by looking at modules and bindings. That is all dynamic. Here both are known when compiling:
#
# * the name of a type `T` is a constant string, made by Base's own `show` when compiling, so that it is
#   exactly what Base prints;
# * what the context knows about the type of the elements is in the type of the stream (`ContextIO`, in `context.jl`),
#   and what Base does with it (`typeinfo_prefix`) is done when compiling, for the type of the container.

Base.show_circular(::ShowStream, @nospecialize(x)) = false

## names of types

# The text that Base's `show` makes for what is shown to a stream (as `stdout`, for which the types of `Main` are
# not written with their module), made when compiling by the `@generated` functions below. A generator runs in
# the world age of its definition, in which what the program defines (its types in `Main`, ...) is not visible, so
# Base's `show` writes `Main.Pt` where it writes `Pt` for the program; the `Main.` is dropped. (Types of other modules that
# the program makes visible with `using` or `import` (`Diagonal` of `LinearAlgebra`) do get their module: a difference with Base.)
host_string(f, x) = replace(sprint(f, x; context = :module => Main), r"(?<![\w.])Main\." => "")

@generated type_name(::Type{T}) where {T} = host_string(show, T)
Base.show(io::ShowStream, ::Type{T}) where {T} = (print(io, type_name(T)); nothing)

## Singletons: functions, `Colon()`, ...
##
## What Base prints for a value that has no fields depends on its type only (the name of the function, and the module
## if it is not visible from where it is shown), but it finds that out with lookups of modules and bindings, in
## libjulia. The text is made when compiling (as for the names of types).

@generated singleton_text(::Type{T}) where {T} = Base.issingletontype(T) ? host_string(show, T.instance) : nothing

function Base.show(io::ShowStream, f::Function)
    text = singleton_text(typeof(f))
    text === nothing && return @invoke Base.show(io::IO, f::Function)
    print(io, text)
    return nothing
end
function Base.print(io::ShowStream, f::Function)
    text = singleton_text(typeof(f))
    text === nothing && return @invoke Base.print(io::IO, f::Function)
    print(io, text)
    return nothing
end
Base.show(io::ShowStream, ::Colon) = (print(io, "Colon()"); nothing)

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

# Base decides how a `Symbol` is written (`:name`, an operator, `Symbol("a b")`) with the tables of the parser, which are in libjulia. A name that is a
# plain ASCII identifier is `:name`, as in Base. For the other symbols that are in the binary the text is what Julia writes, which is made
# when linking (`define_symbol_texts!`); of those that the program makes, the names that are certainly not identifiers or operators are
# `Symbol("...")`, and for any other it's an error, as printing it differently from Base would be wrong
function Base.show(io::ShowStream, s::Symbol)
    if symbol_is_plain(s)
        print(io, ':', string(s))
        return nothing
    end
    text = symbol_text(s)
    if text != 0
        unsafe_write(io, Ptr{UInt8}(text), UInt(@symbolcall strlen(Ptr{UInt8}(text)::Ptr{UInt8})::Int64))
    elseif symbol_is_certainly_quoted(s)
        print(io, "Symbol(")
        show(io, string(s))
        print(io, ')')
    else
        error("show: a Symbol that the program made, and that is not an ASCII identifier, is not supported")
    end
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
show_candidates() = unique!(vcat(DEFAULT_SHOW_CANDIDATES, SHOW_CANDIDATES))

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

## the containers

# the elements of a tuple, each with the type that the tuple has for it
@generated function Base.show(io::ShowStream, t::T) where {T<:Tuple}
    TI = typeinfo_type(io)
    n = fieldcount(T)
    body = Expr(:block, :(print(io, '(')))
    for i in 1:n
        i > 1 && push!(body.args, :(print(io, ", ")))
        typeinfo = (T <: TI && TI <: Tuple && fieldcount(TI) >= i) ? fieldtype(TI, i) : TI
        push!(body.args, :(show_element(typeinfo_io(io, $typeinfo), t[$i], $(fieldtype(T, i)))))
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
            io_i = typeinfo_io(io, $(infos[i]))
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
            show_element(typeinfo_io(io, Any), getfield(x, $i), $(fieldtype(T, i)))
        else
            print(io, Base.undef_ref_str)
        end))
    end
    push!(body.args, :(print(io, ')')), :(nothing))
    return body
end

## arrays of more than one dimension

# Base shows a matrix with `_show_nonempty(io, inferencebarrier(X), ...)`, which makes the matrix a value of the type `Any` for the compiler (so that the code is
# compiled once for all arrays, and not for each type of them): a dynamic call. The same without the barrier.
@device_override Base.show_nd(io::IO, a::AbstractArray, print_matrix::Function, show_full::Bool) =
    Base._show_nd(io, a, print_matrix, show_full, map(Base.unitrange, axes(a)))
@device_override Base._show_nonempty(io::IO, X::AbstractMatrix, prefix::String) = Base._show_nonempty(io, X, prefix, false, axes(X))
@device_override function Base._show_nonempty(io::IO, X::AbstractArray, prefix::String)
    print(io, prefix)
    Base.show_nd(io, X, (io, slice) -> Base._show_nonempty(io, slice, prefix, true, axes(slice)), false)
end

## `text/plain`: `display`, and the alignment of what is in a matrix

# `display(x)` of Julia shows `x` with the first of the displays that can: with nothing else, the `TextDisplay` of the standard output, which writes the
# `text/plain` form of `x` and a newline. (The list of displays is a `Vector` of an abstract type, which can't be resolved when compiling.)
@device_override Base.display(@nospecialize x) = (show(STDOUT, MIME"text/plain"(), x); println(STDOUT); nothing)

# `print_matrix` makes the matrix a value of the type `Any` for the compiler (`inferencebarrier`), as `show` does (see above)
@device_override Base.print_matrix(io::IO, X::AbstractVecOrMat, pre::AbstractString = " ", sep::AbstractString = "  ", post::AbstractString = "",
                                   hdots::AbstractString = "  \u2026  ", vdots::AbstractString = "\u22ee", ddots::AbstractString = "  \u22f1  ",
                                   hmod::Integer = 5, vmod::Integer = 5) =
    Base._print_matrix(io, X, pre, sep, post, hdots, vdots, ddots, hmod, vmod, Base.unitrange(axes(X, 1)), Base.unitrange(axes(X, 2)))

# Base lines up the numbers in a column on their decimal points (`1.5` and `22.25`), by finding where the part before the point ends in what `show` writes,
# with a regular expression, for a `Real`, a `Complex` and a `Rational`. There is no `Regex` in a compiled program, so the same is found with a scan of the
# text. (`alignment(io, x::Integer)` and the other methods are Base's.) Each is what the regular expression of Base matches, in the comment.

# `^(.*?)((?:[\.eEfF].*)?)$`: up to the first `.`, `e`, `E`, `f` or `F`, and the rest
@device_override function Base.alignment(io::IO, x::Real)
    s = sprint(show, x, context = Base.nocolor(io), sizehint = 0)
    i = findfirst(c -> c in ".eEfF", s)
    i === nothing && return (textwidth(s), 0)
    return (textwidth(SubString(s, 1, prevind(s, i))), textwidth(SubString(s, i)))
end

# `^(.*[^ef][\+\-])(.*)$`: up to the last `+` or `-` that has a character before it that is not `e` or `f` (the sign of the imaginary part, and not that of an exponent),
# and the rest
@device_override function Base.alignment(io::IO, x::Complex)
    s = sprint(show, x, context = Base.nocolor(io), sizehint = 0)
    i = findlast(c -> c in "+-", s)
    while i !== nothing
        j = prevind(s, i)
        j >= firstindex(s) && !(s[j] in "ef") && return (textwidth(SubString(s, 1, i)), textwidth(SubString(s, nextind(s, i))))
        i = i == firstindex(s) ? nothing : findprev(c -> c in "+-", s, prevind(s, i))
    end
    return (textwidth(s), 0)
end

# `^(.*?/)(/.*)$`: up to and with the first of the two slashes of the first `//`, and the rest
@device_override function Base.alignment(io::IO, x::Rational)
    s = sprint(show, x, context = Base.nocolor(io), sizehint = 0)
    i = findfirst("//", s)
    i === nothing && return (textwidth(s), 0)
    return (textwidth(SubString(s, 1, first(i))), textwidth(SubString(s, last(i))))
end

# The placeholder that structured matrices (`Diagonal`, `UpperTriangular`, ...) show for the elements that are not stored (`⋅`) is as wide as what would have been
# there: Base measures that with `textwidth(ANSIIterator(s))`, which skips the codes of colors with a regular expression. The streams here have no colors, so it is the width of `s`.
@device_override function Base.replace_with_centered_mark(s::AbstractString; c::AbstractChar = '⋅')
    N = textwidth(s)
    return N == 0 ? string(c) : join(setindex!([" " for i in 1:N], string(c), ceil(Int, N / 2)))
end
