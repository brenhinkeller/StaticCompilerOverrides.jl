# `@cfunction`: a pointer to a function of the program that C can call (a comparison function for `qsort`, the callback of a library).
#
# What Julia makes of it is a wrapper that asks the runtime for the compiled method (`jl_get_abi_converter`), which a program does not have, and until it is there calls the
# function by dispatch (see cfunctions_link.jl, where it is made to call the method). The method is not part of the program if nothing calls it: so the code is compiled
# again with a function for each `@cfunction` that calls it, `cfunction_target_ID(arguments...)`, and that is called from the entry point where it can't be reached.
# Inference says what the `@cfunction`s of the program are (the function, the types of the arguments and of the result), as for the functions of closures.jl.

const SEEN_CFUNCTIONS = Tuple{DataType,Vector{DataType},DataType,Any}[] # (the type of the function, of the arguments, of the result, the function)

# What a function that is the target of a `@cfunction` does, other than call the function: it is a change of a global, so that the call from the entry point is not removed as
# a call that has no effect, and that is not made.
mutable struct CFunctionGuard
    calls::Int
end
const CFUNCTION_GUARD = CFunctionGuard(0)

# The functions of the roots in `Runtime.CFUNCTION_ROOTS` (for the same position in the list)
const CFUNCTION_FUNCTIONS = Any[]

# The arguments of a compilation (the function and its types come first), with the entry point that has the targets of the `@cfunction`s that were found
function rooted_arguments(args)
    isempty(Runtime.CFUNCTION_ROOTS) && return args
    length(args) >= 2 && args[1] isa Function && (args[2] isa Tuple || (args[2] isa DataType && args[2] <: Tuple)) || return args
    entry = rooted_entry(args[1], args[2], collect(zip(Runtime.CFUNCTION_ROOTS, CFUNCTION_FUNCTIONS)))
    return (entry, args[2:end]...)
end

function CC.abstract_eval_cfunction(interp::OverridesInterpreter, e::Expr, sstate::CC.StatementState, sv::CC.AbsIntState)
    try
        ft = CC.abstract_eval_value(interp, e.args[2], sstate, sv)
        f = ft isa Core.Const ? ft.val : (T = CC.widenconst(ft); T isa DataType && Base.issingletontype(T) ? T.instance : nothing)
        ret = e.args[3]
        argtypes = e.args[4]
        if f !== nothing && Base.issingletontype(typeof(f)) && ret isa DataType && isconcretetype(ret) && argtypes isa Core.SimpleVector &&
           all(T -> T isa DataType && isconcretetype(T), argtypes)
            entry = (typeof(f), DataType[argtypes...], ret, f)
            any(s -> s[1] === entry[1] && s[2] == entry[2] && s[3] === entry[3], SEEN_CFUNCTIONS) || push!(SEEN_CFUNCTIONS, entry)
        end
    catch
        # (what is not found is a `@cfunction` that fails to compile, as it did)
    end
    return @invoke CC.abstract_eval_cfunction(interp::CC.AbstractInterpreter, e::Expr, sstate::CC.StatementState, sv::CC.AbsIntState)
end

# The function of the program that is the target of a `@cfunction`, and the roots that are called
function define_cfunction_root(mod::Module, root::Runtime.CFunctionRoot, f)
    name = Symbol(Runtime.cfunction_root_name(root.id))
    argnames = [Symbol(:a, i) for i in eachindex(root.args)]
    params = [:($(argnames[i])::$(root.args[i])) for i in eachindex(root.args)]
    call = :($(QuoteNode(f))($(argnames...)))
    body = root.ret === Nothing ? :($call; nothing) : :($call::$(root.ret))
    Core.eval(mod, :(@noinline function $name($(params...))::$(root.ret)
        $(CFUNCTION_GUARD).calls += 1
        return $body
    end))
    return name
end

# `f`, as an entry point that has the same name and types, and calls the targets of the `@cfunction`s of the program where it can't be reached
function rooted_entry(f::Function, signature, roots::Vector{<:Tuple})
    types = signature isa Tuple ? signature : Tuple(signature.parameters)
    mod = Module(:StaticCFunctionRoots)
    calls = Expr[]
    for (root, g) in roots
        name = define_cfunction_root(mod, root, g)
        args = [:(unsafe_load(Ptr{$T}(($(CFUNCTION_GUARD).calls + $i) % UInt))) for (i, T) in enumerate(root.args)]
        call = :($(name)($(args...)))
        # (the result is stored, where it can't be: if it were not used, the function would not return it, and would not be the one that C calls)
        root.ret === Nothing ? push!(calls, call) : push!(calls, :(unsafe_store!(Ptr{$(root.ret)}(($(CFUNCTION_GUARD).calls + $(length(root.args) + 1)) % UInt), $call)))
    end
    argnames = [Symbol(:a, i) for i in eachindex(types)]
    params = [:($(argnames[i])::$(types[i])) for i in eachindex(types)]
    entry = Symbol(nameof(f))
    Core.eval(mod, :(function $entry($(params...))
        if $(CFUNCTION_GUARD).calls < 0 # (never: it counts; a test of `==` would give the addresses below a value that the compiler knows, and they would be constants that look like pointers)
            $(calls...)
        end
        return $(QuoteNode(f))($(argnames...))
    end))
    return Base.invokelatest(getproperty, mod, entry)
end
