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

## The interpreter of our compilations
#
# Inference is changed below with methods of functions of the compiler (`abstract_call_gf_by_type`, `abstract_call_known`, `optimize`) that GPUCompiler's
# interpreter (`GPUCompiler.GPUInterpreter`, which StaticCompiler's own compilations use too) is the argument of. Methods for that type would change what
# every compilation does, ours or not, and so would have to look at which it is each time. Instead, our compilations have an interpreter of a type of their
# own: the type of a `GPUInterpreter` has the type of the view of the method tables that it looks methods up in as a parameter, and GPUCompiler lets a
# back-end choose the view (`method_table_view`, which says that returning a view of another type "also gives inference a different interpreter type").
# The view here (`OverridesTableView`) holds the one that GPUCompiler makes, and does what it does; and the methods below are for the interpreters that
# have it. No other compilation is of that type, so none is changed.

"""
    OverridesTableView

The view of the method tables that our compilations are made with: that of GPUCompiler (the table of the compilation, then Base's), in a type that is ours, so that the
interpreter that has it is told from others by its type.
"""
struct OverridesTableView{T<:CC.MethodTableView} <: CC.MethodTableView
    inner::T
end
CC.isoverlayed(table::OverridesTableView) = CC.isoverlayed(table.inner)
CC.findall(@nospecialize(sig::Type), table::OverridesTableView; kwargs...) = CC.findall(sig, table.inner; kwargs...)
CC.findsup(@nospecialize(sig::Type), table::OverridesTableView) = CC.findsup(sig, table.inner)

GPUCompiler.method_table_view(job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget, OverridesParams}) =
    OverridesTableView(@invoke GPUCompiler.method_table_view(job::GPUCompiler.CompilerJob))

# GPUCompiler runs the loop and SLP vectorizers only for the jobs that say they can (`can_vectorize`, false by default: it is true for its native and GPU
# targets, and not for StaticCompiler's). Without them a loop with `@simd` is not vectorized, nor its reduction reordered, so the result of `sum`, `dot` and
# the like is that of a plain loop: different in the last digits from what Julia gives (which uses the vectorizer) and less accurate. Our jobs
# (the type of the parameters is ours) run them, as Julia does.
GPUCompiler.can_vectorize(::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget, OverridesParams}) = true

# (the interpreter has the view in a cache, `CachedMethodTable`, when the compiler has one)
const OverridesInterpreter = @static if isdefined(CC, :CachedMethodTable)
    GPUCompiler.GPUInterpreter{<:Union{OverridesTableView, CC.CachedMethodTable{<:OverridesTableView}}}
else
    GPUCompiler.GPUInterpreter{<:OverridesTableView}
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

# whether some method fits a call
function has_methods(interp, arginfo::CC.ArgInfo, @nospecialize(atype), max_methods::Int)
    matches = arginfo.fargs === nothing ?
        CC.find_method_matches(interp, arginfo.argtypes, atype; max_methods) :
        CC.find_method_matches(interp, arginfo.argtypes, atype; max_methods, fargs = arginfo.fargs)
    matches isa CC.FailedMethodMatch && return true # (too many to count)
    return !isempty(matches.applicable)
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

function CC.abstract_call_gf_by_type(interp::OverridesInterpreter, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                     @nospecialize(atype), vtypes::Union{Nothing,Vector{CC.VarState}},
                                     sv::Union{CC.IRInterpretationState{I},CC.InferenceState{I}} where I<:CC.AbstractInterpreter,
                                     max_methods::Int)
    registered = false
    closed = close_abstract_arguments(arginfo)
    # (a call that none of the types that the arguments are closed to has a method for is left as it is: it is not known what the
    # arguments are, and the result of the call is not that it is an error, which would make what calls it one too)
    closed === nothing || has_methods(interp, closed[1], closed[2], max_methods) || (closed = nothing)
    if closed !== nothing && dispatch_needed(interp, arginfo, atype, max_methods)
        original = arginfo.argtypes
        arginfo, atype, registered = closed
        max_methods = max(max_methods, SPLIT_LIMIT[]) # (one method for each type, at most)
        if registered
            fname = f isa Function ? nameof(f) : f isa Type ? f : nameof(typeof(f))
            key = string(fname, "(", join(("::" * (T isa Core.TypeofVararg ? string(T) : string(CC.widenconst(T))) for T in original[2:end]), ", "), ")")
            REGISTERED_CALLS[key] = get(REGISTERED_CALLS, key, 0) + 1
        end
    end
    call = @invoke CC.abstract_call_gf_by_type(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo, atype::Any,
                    vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
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

## `invokelatest`
#
# `invokelatest(f, args...)` calls `f` in the newest world, and so the compiler can't know what it calls: the call is an `Any`, made
# by the runtime. In a program that is compiled there are no newer methods, so it is the call `f(args...)`. Packages use it in the
# macros of logging (`@warn`), and sometimes to avoid a recursion that inference gives up on. So (for what is compiled with our method
# table) inference takes it for the call of `f`, and the statement is made that call before it is optimized.

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.invokelatest), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) >= 2
        inner = CC.ArgInfo(arginfo.fargs === nothing ? nothing : arginfo.fargs[2:end], arginfo.argtypes[2:end])
        return CC.abstract_call(interp, inner, si, vtypes, sv)
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# The function that a statement of the code before it is optimized calls (what a callee refers to, if that is a variable that a
# statement before has loaded: `Base.invokelatest` is a `GlobalRef`, or `getproperty(Base, :invokelatest)`), or `nothing`
function called_function(code, x)
    x isa Core.SSAValue && (x = code[x.id])
    if x isa Expr && x.head === :call && length(x.args) == 3
        f = called_function(code, x.args[1])
        if f === getproperty || f === getglobal
            mod = called_function(code, x.args[2])
            name = x.args[3] isa QuoteNode ? x.args[3].value : x.args[3]
            return mod isa Module && name isa Symbol && isdefined(mod, name) ? getglobal(mod, name) : nothing
        end
        return nothing
    end
    x isa GlobalRef && return isdefined(x.mod, x.name) ? getglobal(x.mod, x.name) : nothing
    x isa QuoteNode && return x.value
    return x isa Expr ? nothing : x
end

# (before optimizing: the statements of `invokelatest` are the calls that inference took them for)
function CC.optimize(interp::OverridesInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult)
    code = opt.src.code
    for pc in eachindex(code)
        st = code[pc]
        st isa Expr && st.head === :call && length(st.args) >= 2 || continue
        called_function(code, st.args[1]) === Core.invokelatest || continue
        code[pc] = Expr(:call, st.args[2:end]...)
    end
    return @invoke CC.optimize(interp::CC.AbstractInterpreter, opt::CC.OptimizationState, caller::CC.InferenceResult)
end
