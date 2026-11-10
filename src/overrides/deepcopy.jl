# `deepcopy`, for any struct.
#
# Base's method of `deepcopy_internal` for a struct reads its fields with `getfield(x, i)` and writes them with `jl_set_nth_field`, for an
# `i` that is only known when the program runs, so the type of each field is not known to the compiler. The copy here is made for each
# type when compiling, with the fields one after the other, each of its own type (`copy_struct`).
#
# An overlay method of `deepcopy_internal` is used for all the calls that it covers, in place of the methods of Base for more specific types
# (an overlay does not stack with Base's methods), so the methods of Base for the other types (arrays, dictionaries, tuples, strings, ...)
# are written again below, with the same behavior, as `static_deepcopy`; it is the function that the recursion is made with.
# A method of `deepcopy_internal` for a struct that another package defines is not used (the struct is copied field by field): it can't be
# called from here, and which methods there are can't be looked up by a generated function.

const DEEPCOPY_ATOMS = Union{Symbol, Core.MethodInstance, Method, GlobalRef, DataType, Union, UnionAll, Task, Regex}

# The methods of `deepcopy_internal` that are not Base's (a package's own, for its types). A generated function can't look at the methods (reflection is not
# allowed in it), so they are looked up when compiling (`register_custom_deepcopy!`, which the functions that compile call) and kept in this list, which
# the generator reads; as with the registered types of dispatch, what is inferred is kept apart for each state of the list (`CANDIDATES_VERSION`).
const CUSTOM_DEEPCOPY = Any[]
const WARNED_DEEPCOPY = Set{Any}()
function register_custom_deepcopy!()
    for m in methods(Base.deepcopy_internal)
        m.module === Base && continue
        any(sig -> sig === m.sig, CUSTOM_DEEPCOPY) && continue
        push!(CUSTOM_DEEPCOPY, m.sig)
        CANDIDATES_VERSION[] += 1
    end
    return nothing
end
custom_deepcopy_methods(T::DataType) =
    String[string(sig.parameters[2] isa Type ? sig.parameters[2] : "...") for sig in CUSTOM_DEEPCOPY if Tuple{typeof(Base.deepcopy_internal), T, IdDict} <: sig]

function static_deepcopy end
function copy_struct end
@device_override Base.deepcopy_internal(x, stackdict::IdDict) = static_deepcopy(x, stackdict)
@device_override function Base.deepcopy(x)
    isbitstype(typeof(x)) && return x
    return static_deepcopy(x, IdDict())::typeof(x)
end

static_deepcopy(x::DEEPCOPY_ATOMS, stackdict::IdDict) = x
static_deepcopy(x::Tuple, stackdict::IdDict) = ntuple(i -> static_deepcopy(x[i], stackdict), length(x))
static_deepcopy(x::Module, stackdict::IdDict) = error("deepcopy of Modules not supported")

function static_deepcopy(x::String, stackdict::IdDict)
    haskey(stackdict, x) && return stackdict[x]::typeof(x)
    y = GC.@preserve x unsafe_string(pointer(x), sizeof(x))
    stackdict[x] = y
    return y
end

function static_deepcopy(x::Memory, stackdict::IdDict)
    haskey(stackdict, x) && return stackdict[x]::typeof(x)
    return static_deepcopy_memory(x, eltype(x), stackdict)
end
function static_deepcopy_memory(x::Memory, ::Type{T}, stackdict::IdDict) where {T}
    isbitstype(T) && return (stackdict[x] = copy(x))
    dest = typeof(x)(undef, length(x))
    stackdict[x] = dest
    xr = Base.memoryref(x)
    dr = Base.memoryref(dest)
    for i in 1:length(x)
        xi = Core.memoryrefnew(xr, i, false)
        if Core.memoryref_isassigned(xi, :not_atomic, false)
            xi = Core.memoryrefget(xi, :not_atomic, false)
            isbits(xi) || (xi = static_deepcopy(xi, stackdict)::typeof(xi))
            Core.memoryrefset!(Core.memoryrefnew(dr, i, false), xi, :not_atomic, false)
        end
    end
    return dest
end

function static_deepcopy(x::Array{T,N}, stackdict::IdDict) where {T,N}
    haskey(stackdict, x) && return stackdict[x]::typeof(x)
    y = stackdict[x] = Array{T,N}(undef, ntuple(Base.Returns(0), Val{N}()))
    setfield!(y, :ref, static_deepcopy(x.ref, stackdict))
    setfield!(y, :size, x.size)
    return y
end

function static_deepcopy(x::GenericMemoryRef, stackdict::IdDict)
    haskey(stackdict, x) && return stackdict[x]::typeof(x)
    mem = getfield(x, :mem)
    dest = Base.memoryref(static_deepcopy(mem, stackdict)::typeof(mem))
    i = Base.memoryrefoffset(x)
    i == 1 || (dest = Core.memoryrefnew(dest, i, true))
    return dest
end

function static_deepcopy(x::Union{Dict,IdDict}, stackdict::IdDict)
    haskey(stackdict, x) && return stackdict[x]::typeof(x)
    isbitstype(eltype(x)) && return (stackdict[x] = copy(x))
    dest = empty(x)
    stackdict[x] = dest
    for (k, v) in x
        dest[static_deepcopy(k, stackdict)] = static_deepcopy(v, stackdict)
    end
    return dest
end

@generated function copy_struct(x::T, stackdict::IdDict) where {T}
    if !isconcretetype(T) || T <: Core.GenericMemory || T <: Array
        return :(error("deepcopy of a value whose type is not known when compiling"))
    end
    # (types with methods of `deepcopy_internal` that can't be written here: they hold what libjulia or the system owns)
    if T <: Union{BigInt, BigFloat, Base.AbstractLock, Core.WaitEntryN}
        return :(error(string("deepcopy of a ", $(string(T)), " is not supported in standalone binaries")))
    end
    # a method of `deepcopy_internal` that a package defines for the type would be what Julia calls, and can't be called from here (see above): so the
    # program says so, and doesn't copy the fields instead, which would be a different result
    custom = custom_deepcopy_methods(T)
    if !isempty(custom)
        T in WARNED_DEEPCOPY || (push!(WARNED_DEEPCOPY, T); @warn string("`deepcopy` of a `", T, "` is not supported in standalone binaries: a method of `deepcopy_internal` defined by a package (",
                                                                         join(custom, ", "), ") applies to it, and is not used there (the fields would be copied one by one, which is not what it does). The program stops if it reaches it."))
    end
    isempty(custom) || return :(error(string("deepcopy of a ", $(string(T)), ": a method of `deepcopy_internal` defined by a package (",
                                             $(join(custom, ", ")), ") is not used in standalone binaries")))
    isbitstype(T) && return :(x)
    nf = fieldcount(T)
    nf == 0 && return :(x)
    if ismutabletype(T)
        steps = Expr[]
        for i in 1:nf
            ft = fieldtype(T, i)
            copyit = isbitstype(ft) ? :(xi) : :(static_deepcopy(xi, stackdict)::$ft)
            push!(steps, :(if isdefined(x, $i)
                xi = getfield(x, $i)
                setfield!(y, $i, $copyit)
            end))
        end
        return quote
            haskey(stackdict, x) && return stackdict[x]::T
            y = $(Expr(:new, T))
            stackdict[x] = y
            $(steps...)
            return y
        end
    end
    T.name.n_uninitialized == 0 || return :(error(string("deepcopy of a ", $(string(T)), ", which has fields that may be undefined, is not supported in standalone binaries")))
    fields = Any[]
    for i in 1:nf
        ft = fieldtype(T, i)
        push!(fields, isbitstype(ft) ? :(getfield(x, $i)) : :(static_deepcopy(getfield(x, $i), stackdict)::$ft))
    end
    return Expr(:new, T, fields...)
end

# Any other type: the fields of a struct, one by one
static_deepcopy(x, stackdict::IdDict) = copy_struct(x, stackdict)
