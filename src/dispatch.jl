# Dynamic dispatch on abstract types, and on `Any`, resolved when compiling.
#
# A call whose argument has an abstract type (`area(x)` with `x::Shape`, from a `Vector{Shape}`) runs the method that fits
# the type that the argument has when the program is run: `ijl_apply_generic`, which looks it up in the method tables of
# the Julia runtime. There are none in a standalone binary. Julia's compiler does resolve one kind of dynamic call
# without them: for an argument of a `Union` type, it tests which type of the union it has and calls the method for that
# one ("union splitting"). So the argument is given the type of the union of the types that it can have.
#
# For an abstract type that has few concrete subtypes, that can all be listed, they are all of the types that were made when
# compiling, and so all of the types that an object of the binary can have. For `Any`, and the abstract types that have
# too many subtypes or some that are not listed (`Number`, `AbstractString`: `Complex{T}`, `SubString{T}`), it is the
# types that were *registered* (the ones of `show`, and what `add_dispatch_candidates!` adds) that are subtypes of it. An object of
# another type is not known when compiling, so a call that it reaches is a `MethodError` when the program runs (which compiling
# warns of, once for what it has done this way).
#
# That is done by inference (not in the code that results): when a call that is a dispatch on its arguments is found (more than one
# method fits, or too many to be counted, or the one that does doesn't fit all that the arguments can be), it is inferred again with the
# abstract types in its arguments replaced by the unions, and if that can be split, it is that that is used. Calls of one method that fits
# all that the arguments can be are left alone.

using StaticCompiler.GPUCompiler: GPUCompiler
using InteractiveUtils: subtypes

const CC = Base.Compiler

# The most concrete subtypes of one abstract type that we list and dispatch over.
const DISPATCH_LIMIT = Ref(16)

# The most types that a call is split in: that of the listed subtypes of an abstract type, or of the registered types. (Julia
# limits the splitting of a call by the number of its cases: `x + y` of two arguments of 23 types is not split with the limit
# at 32, and is with 64.) `0` turns the use of the registered types off.
const SPLIT_LIMIT = Ref(64)

# `GPUCompiler.inference_params` of the code that is compiled with our method table: the number of types that Julia's inference
# splits a union in, which is 4 by default, is that of the types that we dispatch over
function GPUCompiler.inference_params(job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget, OverridesParams})
    base = @invoke GPUCompiler.inference_params(job::GPUCompiler.CompilerJob)
    job.config.target.method_table === method_table || return base
    return CC.InferenceParams(base; max_union_splitting = max(base.max_union_splitting, SPLIT_LIMIT[]))
end

# whether the code of this interpreter is compiled with our method table (and not StaticCompiler's)
function uses_our_method_table(interp::GPUCompiler.GPUInterpreter)
    t = CC.method_table(interp)
    hasproperty(t, :table) && (t = t.table) # (a cache of the table)
    hasproperty(t, :tables) && return any(mt -> mt === method_table, t.tables) # (GPUCompiler 2.22: a list of the tables)
    while true
        hasproperty(t, :mt) && t.mt === method_table && return true
        hasproperty(t, :parent) || return false
        t = t.parent
    end
end

## the types that are registered: those of `show` (`add_show_candidates!`), which are the types that a value of `Any` is expected to have

"""
    add_dispatch_candidates!(types...)

Add concrete types to the ones that a call with an argument of the type `Any` (an element of a `Vector{Any}`, say), or of an abstract type
that has too many subtypes to list (`Number`), dispatches over in compiled code: the usual ones (numbers, `String`, `Char`, `Symbol`,
`Nothing`, `Missing`, `Vector{Any}`), and these. For example `add_dispatch_candidates!(MyType, Tuple{Int,Float64})`. A value of another
type that reaches such a call is an error when the program runs (compiling says which calls were made this way). It is the same list
as that of `show` (see [`add_show_candidates!`](@ref)). Call it before compiling the code that has such values.
"""
add_dispatch_candidates!(types::Type...) = add_show_candidates!(types...)

# (without `Vector{Any}`, which `show` needs for lists in lists, but which has methods of arithmetic and the like, that call for much of what is
# not there, for every call with an `Any` that is a number: register it if you have lists in the values of the calls that you make)
const DEFAULT_DISPATCH_CANDIDATES = Type[T for T in DEFAULT_SHOW_CANDIDATES if T !== Vector{Any}]
dispatch_candidates() = unique!(vcat(DEFAULT_DISPATCH_CANDIDATES, SHOW_CANDIDATES))

## the unions that an abstract type is made

# The union of the concrete subtypes of the abstract type `T`, or `nothing` if there is no such type, or too many of them, or
# we can't tell (a subtype that is not a concrete `DataType` and is not abstract). The types that are loaded now are
# the closed world of the program that is compiled now: (it is looked up again in a newer world.)
const CLOSED_SUBTYPES = Dict{Tuple{Any,UInt},Any}()
function listed_union(@nospecialize(T))
    T isa DataType && isabstracttype(T) && T !== Any || return nothing
    get!(CLOSED_SUBTYPES, (T, Base.get_world_counter())) do
        found = DataType[]
        function walk(S)
            for s in subtypes(S)
                s isa DataType || return false # (a parametric type, `UnionAll`: its instances can't be listed)
                if isabstracttype(s)
                    walk(s) || return false
                elseif isconcretetype(s)
                    push!(found, s)
                else
                    return false
                end
                length(found) <= DISPATCH_LIMIT[] || return false
            end
            return true
        end
        walk(T) && 2 <= length(found) <= DISPATCH_LIMIT[] ? Union{found...} : nothing
    end
end

# The union of the registered types that are subtypes of `T` (`Any`, or an abstract type that can't be listed), or `nothing`
function registered_union(@nospecialize(T))
    T isa Type && !(T <: Type) && (T === Any || isabstracttype(Base.unwrap_unionall(T))) || return nothing # (`Type{X}` is not an abstract type of objects)
    found = Type[C for C in dispatch_candidates() if C <: T]
    1 <= length(found) <= SPLIT_LIMIT[] || return nothing
    return Union{found...}
end

# The calls that were made over the registered types, for the warning: function, and the types of its arguments
const REGISTERED_CALLS = Dict{String,Int}()

# The arguments of a call with the abstract types made unions, and the `Tuple` of their types (that of the function comes first, and
# is not changed), or `nothing` if there is none to change; and whether one of them was made of the registered types
function close_abstract_arguments(arginfo::CC.ArgInfo)
    argtypes = copy(arginfo.argtypes)
    changed = false
    registered = false
    for i in 2:length(argtypes)
        argtypes[i] isa Core.TypeofVararg && continue # (a call with the arguments that are the rest of a splat: not known)
        T = CC.widenconst(argtypes[i]) # (a constant is of a concrete type; the rest of what is known of an argument is lost)
        u = listed_union(T)
        if u === nothing
            u = registered_union(T)
            u === nothing && continue
            registered = true
        end
        argtypes[i] = u
        changed = true
    end
    changed || return nothing
    return CC.ArgInfo(arginfo.fargs, argtypes), CC.argtypes_to_type(argtypes), registered
end

# whether the call is a dispatch on the types of the arguments: more than one method fits, or too many to be counted, or the one
# that does doesn't fit all that the arguments can be. (Julia resolves a call of few methods by testing the types that they have
# in their signatures, and calls that method with the argument as an object of *that* type: for an `Any` that is an abstract type
# that is not listed, and what is done with it in that method is a dispatch again. So it is the types of the objects that are
# tested here, and a type that is not known is an error.)
function dispatch_needed(interp, arginfo::CC.ArgInfo, @nospecialize(atype), max_methods::Int)
    matches = arginfo.fargs === nothing ?
        CC.find_method_matches(interp, arginfo.argtypes, atype; max_methods) :
        CC.find_method_matches(interp, arginfo.argtypes, atype; max_methods, fargs = arginfo.fargs)
    matches isa CC.FailedMethodMatch && return true
    return length(matches.applicable) > 1 || !CC.fully_covering(matches)
end

# What Julia is told of the methods that fit, as not covering what the arguments can be, so that the call it makes is a test of each
# type (and not of all but the last, which would be what is left): what is left is a `MethodError`. For a call over the registered
# types, which an argument of the type that it has (`Any`) can be more than, so that the types that are not registered are not
# calls of the last method. (`fully_covers` of the matches of one of the types is what the union splitting of Julia looks at.)
function uncovered(info::CC.MethodMatchInfo)
    matches = Core.MethodMatch[Core.MethodMatch(m.spec_types, m.sparams, m.method, false) for m in info.results.matches]
    results = CC.MethodLookupResult(matches, info.results.valid_worlds, info.results.ambig)
    new = CC.MethodMatchInfo(results, info.mt, info.atype, false)
    copyto!(new.edges, info.edges)
    copyto!(new.needs_mi_edges, info.needs_mi_edges)
    copyto!(new.call_results, info.call_results)
    return new
end
function uncovered(info::CC.UnionSplitInfo)
    split = copy(info.split)
    split[end] = uncovered(split[end])
    return CC.UnionSplitInfo(split)
end
uncovered(info) = info

function CC.abstract_call_gf_by_type(interp::GPUCompiler.GPUInterpreter, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                     @nospecialize(atype), vtypes::Union{Nothing,Vector{CC.VarState}},
                                     sv::Union{CC.IRInterpretationState{I},CC.InferenceState{I}} where I<:CC.AbstractInterpreter,
                                     max_methods::Int)
    registered = false
    if uses_our_method_table(interp)
        closed = close_abstract_arguments(arginfo)
        if closed !== nothing && dispatch_needed(interp, arginfo, atype, max_methods)
            original = arginfo.argtypes
            arginfo, atype, registered = closed
            max_methods = max(max_methods, SPLIT_LIMIT[]) # (one method for each type, at most)
            if registered
                fname = f isa Function ? nameof(f) : f isa Type ? f : nameof(typeof(f))
                key = string(fname, "(", join(("::" * string(CC.widenconst(T)) for T in original[2:end]), ", "), ")")
                REGISTERED_CALLS[key] = get(REGISTERED_CALLS, key, 0) + 1
            end
        end
    end
    call = @invoke CC.abstract_call_gf_by_type(interp::CC.AbstractInterpreter, f, arginfo, si, atype, vtypes, sv, max_methods::Int)
    registered || return call
    return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
        return CC.CallMeta(result.rt, result.exct, result.effects, uncovered(result.info), result.refinements)
    end
end

# What the compile that has just been done did over the registered types, as a debug message (shown with
# `JULIA_DEBUG=StaticCompilerOverrides`): a program that has a value of a type that is not one of them aborts when it
# reaches such a call (and says which one)
function report_registered_dispatch()
    isempty(REGISTERED_CALLS) && return
    calls = sort!(collect(keys(REGISTERED_CALLS)))
    empty!(REGISTERED_CALLS)
    shown = join(("`$c`" for c in first(calls, 5)), ", ") * (length(calls) > 5 ? ", and $(length(calls) - 5) more" : "")
    @debug "Dispatch on `Any` or on an abstract type with unlisted subtypes was resolved over registered types: a value of another type that reaches such a call aborts the program with a MethodError. Add types with `add_dispatch_candidates!`." calls = shown candidates = join(string.(dispatch_candidates()), ", ") _id = :static_dispatch_candidates
end
