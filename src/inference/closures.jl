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

# Whether a call has been made over the candidates in the compilation that is made now
const FUNCTION_UNION_USED = Ref(false)

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
        (root === Base || root === Core || root === Base.Compiler || root === StaticRuntime || root === StaticTools || root === StaticCompiler) && return false
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
function function_union(@nospecialize(T), argtypes::Vector{Any}, position::Int = 1; candidates = FUNCTION_CANDIDATES)
    any(a -> a isa Core.TypeofVararg, argtypes) && return nothing
    world = Base.get_world_counter()
    found = Type[]
    for C in candidates
        C <: T || continue
        sig = Tuple{(i == position ? C : CC.widenconst(a) for (i, a) in enumerate(argtypes))...}
        ms = Base._methods_by_ftype(sig, nothing, -1, world)
        ms isa Vector && !isempty(ms) || continue
        push!(found, C)
        length(found) > SPLIT_LIMIT[] && return nothing
    end
    isempty(found) && return nothing
    # (a call over one type is a call of that function, with no test that `f` is one: the type that is not callable, and that has no method, is the case that the others are tested against)
    length(found) == 1 && return Union{found[1], Nothing}
    return Union{found...}
end

## Callbacks
#
# A program that keeps functions where their types are lost (the listeners of an `Observable`, in a `Vector{Pair{Int,Any}}`) calls them with a call of a function that is not known,
# which is made over the types of all the functions that the program has (`FUNCTION_CANDIDATES`): `string`, `iterate` and the other functions that it passes as arguments are among them, and are
# called with whatever the value is, which may be something that they can't be compiled for. The code that stores the functions says what is stored (`note_callback(T, f)`: `f` is
# called with a value of the type `T`), and the code that calls them says that it does (`call_callback(T, f, args...)`, which is `f(args...)`), so that the call is made over
# those of the type `T`, and no others.

"""
    StaticRuntime.note_callback(T, f)

For code that is compiled with this package: say that the function `f` (the type that it has when this is inferred) may be called by a `call_callback(T, g, args...)`
of the same `T`, where the compiler does not know that `g` is `f`. Does nothing when the code runs.
"""
@noinline note_callback(@nospecialize(T), @nospecialize(f)) = nothing

"""
    StaticRuntime.call_callback(T, f, args...)

`f(args...)`, for an `f` that is one of those of `note_callback(T, f)`: when compiling with this package, the call is made over the types of those functions, and not over all those
that the program has.
"""
call_callback(@nospecialize(T), @nospecialize(f), args...) = f(args...)

# The callbacks that the compilation that is made now has found, and whether it has a call that they are for
const SEEN_CALLBACKS = Tuple{Type,Type}[]
const CALLBACK_CALL_REQUESTED = Ref(false)

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(note_callback), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) == 3
        V = callback_value_type(arginfo.argtypes[2])
        F = CC.widenconst(arginfo.argtypes[3])
        if V !== nothing && F isa DataType && isconcretetype(F) && !(F <: Core.Builtin) && !((V, F) in SEEN_CALLBACKS)
            push!(SEEN_CALLBACKS, (V, F))
        end
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# the `T` of `Type{T}` that an argument is (a constant, or of that type), or `nothing`
function callback_value_type(@nospecialize(t))
    t isa Core.Const && return t.val isa Type ? t.val : nothing
    T = CC.widenconst(t)
    return T isa DataType && T <: Type && length(T.parameters) == 1 && T.parameters[1] isa Type ? T.parameters[1] : nothing
end

# `call_callback(T, f, args...)` is inferred as the call `f(args...)`, for the functions of the callbacks of `T` if there are some, and as for any function that is not known if not
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(call_callback), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    if length(arginfo.argtypes) >= 3
        CALLBACK_CALL_REQUESTED[] = true
        V = callback_value_type(arginfo.argtypes[2])
        inner = copy(arginfo.argtypes[3:end])
        T = CC.widenconst(inner[1])
        fargs = arginfo.fargs === nothing ? nothing : arginfo.fargs[3:end]
        if unknown_function_type(T) && V !== nothing
            candidates = Type[F for (W, F) in CALLBACK_CANDIDATES if W === V]
            # (none registered for `T`: nothing is called, as far as is known; the compilation is made again if the code that is inferred registers one)
            isempty(candidates) && return CC.Future{CC.CallMeta}(CC.CallMeta(Union{}, Union{}, CC.EFFECTS_THROWS, CC.NoCallInfo()))
            u = function_union(T, inner, 1; candidates)
            if u !== nothing
                FUNCTION_UNION_USED[] = true
                inner[1] = u
                call = CC.abstract_call(interp, CC.ArgInfo(fargs, inner), si, vtypes, sv)
                return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
                    return CC.CallMeta(result.rt, result.exct, result.effects, uncovered(result.info), result.refinements)
                end
            end
        end
        return CC.abstract_call(interp, CC.ArgInfo(fargs, inner), si, vtypes, sv)
    end
    return @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
end

# A recursion through callbacks (a `map!`ed observable that listens to an observable and sets another one of the same type, which notifies the callbacks of its own) is not widened.
# Julia limits what it infers for a method that it is already inferring with other types (two `MapCall`s of different functions: the second is inferred as `MapCall`, with no
# parameters), and the call that is made with those types is then a dispatch over the types that the parameters could be, which a program cannot do. The callbacks are of
# finite many types (those registered), so the inference ends without the limit.
function CC.edge_matches_sv(interp::OverridesInterpreter, frame::CC.AbsIntState, method::Method, @nospecialize(sig), sparams::Core.SimpleVector,
                            hardlimit::Bool, sv::CC.AbsIntState)
    if !hardlimit && sig isa DataType && isconcretetype(sig) && !isempty(CALLBACK_CANDIDATES)
        F = sig.parameters[1]
        any(c -> c[2] === F, CALLBACK_CANDIDATES) && return false
    end
    return @invoke CC.edge_matches_sv(interp::CC.AbstractInterpreter, frame::CC.AbsIntState, method::Method, sig::Any, sparams::Core.SimpleVector,
                                      hardlimit::Bool, sv::CC.AbsIntState)
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
            FUNCTION_UNION_USED[] = true
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
                FUNCTION_UNION_USED[] = true
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
# resolve (it failed, or it is not `strict`: such a call aborts the program), or a `@cfunction` (see cfunctions.jl), until it finds no more
function with_function_candidates(compile; strict::Bool = true)
    empty!(FUNCTION_CANDIDATES)
    empty!(Runtime.CFUNCTION_ROOTS)
    empty!(CFUNCTION_FUNCTIONS)
    empty!(CALLBACK_CANDIDATES)
    local failure = nothing
    for pass in 1:MAX_FUNCTION_PASSES
        empty!(SEEN_FUNCTIONS)
        empty!(SEEN_FUNCTIONS_SET)
        empty!(SEEN_CFUNCTIONS)
        empty!(SEEN_CALLBACKS)
        empty!(SEEN_BOXES)
        CALLBACK_CALL_REQUESTED[] = false
        FUNCTION_DISPATCH_REQUESTED[] = false
        FUNCTION_UNION_USED[] = false
        failure = nothing
        result = nothing
        started = time()
        try
            result = compile()
        catch e
            (e isa UnsupportedCodeError || e isa InferenceError) || rethrow()
            failure = e
        end
        new = Type[T for T in SEEN_FUNCTIONS if !(T in FUNCTION_CANDIDATES)]
        @debug "compilation pass" pass seconds = round(time() - started; digits = 1) candidates = length(FUNCTION_CANDIDATES) new = length(new) cfunctions = length(Runtime.CFUNCTION_ROOTS) failed = failure !== nothing requested = FUNCTION_DISPATCH_REQUESTED[] _id = :static_passes
        newc = [c for c in SEEN_CFUNCTIONS if !any(r -> r.ftype === c[1] && r.args == c[2] && r.ret === c[3], Runtime.CFUNCTION_ROOTS)]
        more_functions = FUNCTION_DISPATCH_REQUESTED[] && !isempty(new) && (failure !== nothing || !strict || FUNCTION_UNION_USED[])
        newcb = Tuple{Type,Type}[c for c in SEEN_CALLBACKS if !(c in CALLBACK_CANDIDATES)]
        more_callbacks = CALLBACK_CALL_REQUESTED[] && !isempty(newcb)
        # (the types of the boxes that were found with the types that the last pass had are the ones for the next: until they are the same)
        more_boxes = any(((k, T),) -> T === Any ? haskey(BOX_TYPES, k) : get(BOX_TYPES, k, nothing) !== T, SEEN_BOXES)
        retry = pass < MAX_FUNCTION_PASSES && (more_functions || more_callbacks || !isempty(newc) || more_boxes)
        if retry
            if more_boxes
                for (k, T) in SEEN_BOXES
                    T === Any ? delete!(BOX_TYPES, k) : (BOX_TYPES[k] = T)
                end
                BOX_VERSION[] += 1
            end
            more_callbacks && append!(CALLBACK_CANDIDATES, newcb)
            more_functions && append!(FUNCTION_CANDIDATES, new)
            for c in newc
                id = length(Runtime.CFUNCTION_ROOTS) + 1
                push!(Runtime.CFUNCTION_ROOTS, Runtime.CFunctionRoot(id, c[1], c[2], c[3]))
                push!(CFUNCTION_FUNCTIONS, c[4])
            end
            continue
        end
        failure === nothing || throw(failure)
        return result
    end
end
