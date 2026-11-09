# Calls of functions that are not known when compiling: a `Vector{Function}`, a `Dict` of functions, a closure that calls itself (the variable that it is in
# is boxed, a `Core.Box` of the type `Any`), a function in a field of an abstract type.
#
# `f(x)` where `f` is a `Function` (or an `Any`) is a call of the method that is for the type of the function that `f` is when the program runs, which is a lookup
# in the method tables of Julia: `ijl_apply_generic`. As for arguments of an abstract type (see dispatch.jl), the call is made over a union of the types that `f`
# can have, which the compiler splits in a test of the type for each. The types are those of the functions that the code that is compiled has: the closures that it
# makes, and the functions that it passes or stores (`sin` in `Function[sin, cos]`, and what is in a constant, `const FS = Function[sin, x -> 2x]`).
#
# Where that code is is not known before it is inferred, and the call is inferred before all of it is. So a compilation that has such a call, and fails (or, with
# `strict = false`, would abort at the call), is made again with the types that the first found (`with_function_candidates`), until it finds no more.

const MAX_FUNCTION_PASSES = 6

# The types of functions that were found (in the order that they were) by the compilation that is made now
const SEEN_FUNCTIONS = Type[]
const SEEN_FUNCTIONS_SET = Set{Type}()

# Whether the compilation that is made now has a call of a function that is not known, that has been looked at
const FUNCTION_DISPATCH_REQUESTED = Ref(false)

# A type that a function can have that is of interest: not a function of the compiler (the types of builtins and intrinsics have no methods), and not
# something that the runtime of the program does (the functions of this package that are run when the program starts, or ends)
function interesting_function_type(@nospecialize(T))
    T isa DataType && isconcretetype(T) && T <: Function || return false
    T <: Core.Builtin && return false
    T <: Core.IntrinsicFunction && return false
    T <: Core.OpaqueClosure && return false
    mod = parentmodule(T)
    mod === Core.Compiler && return false
    mod === Base.Compiler && return false
    return true
end

function note_function!(@nospecialize(T))
    interesting_function_type(T) || return
    if !(T in SEEN_FUNCTIONS_SET)
        push!(SEEN_FUNCTIONS_SET, T)
        push!(SEEN_FUNCTIONS, T)
    end
    return
end

# The functions in a value that the code refers to as a constant (`FS` of `const FS = Function[sin, cos]`): in an array, a tuple, a `Dict`, the fields of a struct.
# (Not for what is large, or deep: a function in a constant of that kind is found when it is made, if it is.)
function note_functions_in!(@nospecialize(x), depth::Int = 0, budget::Base.RefValue{Int} = Ref(2000))
    budget[] <= 0 && return
    budget[] -= 1
    if x isa Function
        note_function!(typeof(x))
    elseif depth >= 3 || x isa Type || x isa Module || x isa Symbol || x isa String || x isa Number || x isa Char
        return
    elseif x isa Array || x isa Core.GenericMemory
        isbitstype(eltype(x)) && return
        for i in eachindex(x)
            isassigned(x, i) && note_functions_in!(x[i], depth + 1, budget)
        end
    elseif x isa Tuple
        for e in x
            note_functions_in!(e, depth + 1, budget)
        end
    elseif x isa Dict
        for (k, v) in x
            note_functions_in!(k, depth + 1, budget)
            note_functions_in!(v, depth + 1, budget)
        end
    elseif isstructtype(typeof(x)) && !(x isa Core.CodeInstance) && !(x isa Core.MethodInstance) && !(x isa Method) && !(x isa Core.TypeName) && fieldcount(typeof(x)) <= 16
        for i in 1:fieldcount(typeof(x))
            isdefined(x, i) && note_functions_in!(getfield(x, i), depth + 1, budget)
        end
    end
    return
end

# What the statements of a method that is inferred refer to: the functions that are made (a closure is `new` of its type, which the type of the statement says), the
# functions that are values of statements, and the functions that are arguments of calls (`map(sin, xs)`, `Function[sin, cos]`: not the function that is called)
# Only the code of the program is looked at (not that of Base, or of the standard libraries, whose functions pass the functions of the program around, and are
# the ones that call them with the types that they have): a function that is stored where its type is lost is stored by the program (`Base.Fix2(+, 1)` is a call in
# it, and its type is the type of that statement)
const USER_MODULES = Dict{Module,Bool}()
function user_module(mod::Module)
    get!(USER_MODULES, mod) do
        root = Base.moduleroot(mod)
        (root === Base || root === Core || root === Base.Compiler || root === StaticCompilerOverrides || root === StaticTools || root === StaticCompiler) && return false
        dir = try pkgdir(root) catch; nothing end
        dir !== nothing && startswith(dir, Sys.STDLIB) && return false
        return true
    end
end
function note_functions_of!(code, types, linfo)
    def = linfo isa Core.MethodInstance ? linfo.def : nothing
    mod = def isa Method ? def.module : def isa Module ? def : nothing
    mod === nothing && return
    user_module(mod) || return
    try
        note_functions_in_code!(code, types)
    catch
        # (what is found is only what the calls of unknown functions are made over: not finding is not an error)
    end
    return
end
function note_functions_in_code!(code, types)
    for pc in eachindex(code)
        t = pc <= length(types) && isassigned(types, pc) ? types[pc] : nothing
        if t !== nothing
            if t isa Core.Const
                note_functions_in!(t.val)
            else
                note_function!(CC.widenconst(t))
            end
        end
        st = code[pc]
        st isa Expr || continue
        skip = st.head === :call ? 2 : st.head === :invoke ? 3 : st.head === :new ? 2 : st.head === :foreigncall ? 0 : 1
        skip == 0 && continue
        for i in skip:length(st.args)
            a = st.args[i]
            v = a isa GlobalRef ? (isdefined(a.mod, a.name) && isconst(a.mod, a.name) ? getglobal(a.mod, a.name) : nothing) :
                a isa QuoteNode ? a.value : a isa Core.SSAValue || a isa Core.Argument || a isa Expr ? nothing : a
            v === nothing && continue
            note_functions_in!(v)
        end
    end
    return
end

# The types of the candidates that fit a call, as a union, or `nothing`: those that are subtypes of the type that the function is known to have, and that a method of the
# call is for (the arity, and the types of the arguments that are known: the one that has none is not a case of it)
function function_union(@nospecialize(T), argtypes::Vector{Any}, position::Int = 1)
    any(a -> a isa Core.TypeofVararg, argtypes) && return nothing
    world = Base.get_world_counter()
    found = Type[]
    for C in FUNCTION_CANDIDATES
        C <: T || continue
        sig = Tuple{(i == position ? C : CC.widenconst(a) for (i, a) in enumerate(argtypes))...}
        ms = Base._methods_by_ftype(sig, nothing, -1, world)
        ms isa Vector && !isempty(ms) || continue
        push!(found, C)
        length(found) > SPLIT_LIMIT[] && return nothing
    end
    isempty(found) && return nothing
    return Union{found...}
end

# The type of a function that is not known: `Function`, a type of functions that has subtypes (`Base.Callable` is not one: it has types), or `Any`
function unknown_function_type(@nospecialize(T))
    T === Any && return true
    T isa DataType && !Base.isType(T) && isabstracttype(T) && T <: Function
end

# A call of `f(args...)` of an `f` that is not known (inference reaches it here, from `abstract_call`, and without this, a call of a type that has `Builtin` in it is
# a call that gives `Any`): over the types of the candidates, if there are some
function CC.abstract_call_unknown(interp::OverridesInterpreter, @nospecialize(ft), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                  vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
    T = CC.widenconst(ft)
    if unknown_function_type(T) && !(ft isa CC.PartialOpaque)
        FUNCTION_DISPATCH_REQUESTED[] = true
        u = isempty(FUNCTION_CANDIDATES) ? nothing : function_union(T, arginfo.argtypes)
        if u !== nothing
            argtypes = copy(arginfo.argtypes)
            argtypes[1] = u
            closed = CC.ArgInfo(arginfo.fargs, argtypes)
            call = CC.abstract_call(interp, closed, si, vtypes, sv)
            return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
                return CC.CallMeta(result.rt, result.exct, result.effects, uncovered(result.info), result.refinements)
            end
        end
    end
    return @invoke CC.abstract_call_unknown(interp::CC.AbstractInterpreter, ft::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                            vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# A call with keyword arguments of a function that is not known, `Core.kwcall(keywords, f, args...)`: the function is the third of the arguments
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.kwcall), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) >= 3
        T = CC.widenconst(arginfo.argtypes[3])
        if unknown_function_type(T)
            FUNCTION_DISPATCH_REQUESTED[] = true
            u = isempty(FUNCTION_CANDIDATES) ? nothing : function_union(T, arginfo.argtypes, 3)
            if u !== nothing
                argtypes = copy(arginfo.argtypes)
                argtypes[3] = u
                closed = CC.ArgInfo(arginfo.fargs, argtypes)
                call = @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, closed::CC.ArgInfo, si::CC.StmtInfo,
                                                      vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
                return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
                    return CC.CallMeta(result.rt, result.exct, result.effects, uncovered(result.info), result.refinements)
                end
            end
        end
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# Compile with the types of functions that the code has: `compile` is run, and again with what it found if it has a call of an unknown function that it could not
# resolve (it failed, or it is not `strict`: such a call aborts the program), until it finds no more
function with_function_candidates(compile; strict::Bool = true)
    empty!(FUNCTION_CANDIDATES)
    local failure = nothing
    for pass in 1:MAX_FUNCTION_PASSES
        empty!(SEEN_FUNCTIONS)
        empty!(SEEN_FUNCTIONS_SET)
        FUNCTION_DISPATCH_REQUESTED[] = false
        failure = nothing
        result = nothing
        try
            result = compile()
        catch e
            (e isa UnsupportedCodeError || e isa InferenceError) || rethrow()
            failure = e
        end
        new = Type[T for T in SEEN_FUNCTIONS if !(T in FUNCTION_CANDIDATES)]
        retry = FUNCTION_DISPATCH_REQUESTED[] && !isempty(new) && (failure !== nothing || !strict) && pass < MAX_FUNCTION_PASSES
        if retry
            append!(FUNCTION_CANDIDATES, new)
            continue
        end
        failure === nothing || throw(failure)
        return result
    end
end
