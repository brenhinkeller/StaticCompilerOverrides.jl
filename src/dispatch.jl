# Dynamic dispatch on abstract types, resolved when compiling.
#
# A call whose argument has an abstract type (`area(x)` with `x::Shape`, from a `Vector{Shape}`) runs the method that fits
# the type that the argument has when the program is run: `ijl_apply_generic`, which looks it up in the method tables of
# the Julia runtime. There are none in a standalone binary. Julia's compiler does resolve one kind of dynamic call
# without them: for an argument of a `Union` type, it tests which type of the union it has and calls the method for that
# one ("union splitting"). So the argument is given the type of the union of the concrete subtypes of the abstract type: all
# of the types that were made when compiling, and so all of the types that an object of the binary can have.
#
# That is done by inference (not in the code that results): when a call that needs to be dispatched on is found (more than one
# method fits, or too many to be counted), it is inferred again with the abstract types in its arguments replaced by the
# unions of their concrete subtypes, and if that can be split, it is that that is used. Calls that don't need a dispatch (one
# method, which is called directly) are left alone, and so are the arguments of types that have too many subtypes (`Any`,
# `Number`), or that have a subtype that we can't list (a parametric type that is not instantiated). A call to a type of
# an object that does not exist when compiling, which is then a call that can't happen, is a `MethodError`, as in Julia.

using StaticCompiler.GPUCompiler: GPUCompiler
using InteractiveUtils: subtypes

const CC = Base.Compiler

# The most concrete subtypes of one abstract type that we dispatch over, and so that a call is split in.
const DISPATCH_LIMIT = Ref(16)

# `GPUCompiler.inference_params` of the code that is compiled with our method table: the number of types that Julia's inference
# splits a union in, which is 4 by default, is that of the types that we dispatch over
function GPUCompiler.inference_params(job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget})
    base = @invoke GPUCompiler.inference_params(job::GPUCompiler.CompilerJob)
    job.config.target.method_table === method_table || return base
    return CC.InferenceParams(base; max_union_splitting = max(base.max_union_splitting, DISPATCH_LIMIT[]))
end

# whether the code of this interpreter is compiled with our method table (and not StaticCompiler's)
function uses_our_method_table(interp::GPUCompiler.GPUInterpreter)
    t = CC.method_table(interp)
    hasproperty(t, :table) && (t = t.table) # (a cache of the table)
    while true
        hasproperty(t, :mt) && t.mt === method_table && return true
        hasproperty(t, :parent) || return false
        t = t.parent
    end
end

# The union of the concrete subtypes of the abstract type `T`, or `nothing` if there is no such type, or too many of them, or
# we can't tell (a subtype that is not a concrete `DataType` and is not abstract). The types that are loaded now are
# the closed world of the program that is compiled now: (it is looked up again in a newer world.)
const CLOSED_SUBTYPES = Dict{Tuple{Any,UInt},Any}()
function concrete_union(@nospecialize(T))
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

# The arguments of a call with the abstract types made unions (see `concrete_union`), and the `Tuple` of their types (that of the function
# comes first, and is not changed), or `nothing` if there is none to change
function close_abstract_arguments(arginfo::CC.ArgInfo)
    argtypes = copy(arginfo.argtypes)
    changed = false
    for i in 2:length(argtypes)
        u = concrete_union(CC.widenconst(argtypes[i])) # (a constant is of a concrete type; the rest of what is known of an argument is lost)
        u === nothing && continue
        argtypes[i] = u
        changed = true
    end
    changed || return nothing
    return CC.ArgInfo(arginfo.fargs, argtypes), CC.argtypes_to_type(argtypes)
end

# whether the call needs a dispatch at run time: more than one method fits, or there are too many of them to be counted
function dispatch_needed(interp, arginfo::CC.ArgInfo, @nospecialize(atype), max_methods::Int)
    matches = arginfo.fargs === nothing ?
        CC.find_method_matches(interp, arginfo.argtypes, atype; max_methods) :
        CC.find_method_matches(interp, arginfo.argtypes, atype; max_methods, fargs = arginfo.fargs)
    matches isa CC.FailedMethodMatch && return true
    return length(matches.applicable) > 1
end

function CC.abstract_call_gf_by_type(interp::GPUCompiler.GPUInterpreter, @nospecialize(f), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                     @nospecialize(atype), vtypes::Union{Nothing,Vector{CC.VarState}},
                                     sv::Union{CC.IRInterpretationState{I},CC.InferenceState{I}} where I<:CC.AbstractInterpreter,
                                     max_methods::Int)
    if uses_our_method_table(interp)
        closed = close_abstract_arguments(arginfo)
        if closed !== nothing && dispatch_needed(interp, arginfo, atype, max_methods)
            arginfo, atype = closed
            max_methods = max(max_methods, DISPATCH_LIMIT[]) # (one method for each type, at most)
        end
    end
    return @invoke CC.abstract_call_gf_by_type(interp::CC.AbstractInterpreter, f, arginfo, si, atype, vtypes, sv, max_methods::Int)
end
