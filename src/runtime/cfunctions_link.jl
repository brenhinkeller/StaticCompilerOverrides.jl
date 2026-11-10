# `@cfunction`, in the code that is generated (see cfunctions.jl for what is done before).
#
# Julia gives the C function of `@cfunction(f, R, (A...))` as a wrapper, `jlcapi_f_N`, that calls a function that it asks the runtime for (`jl_get_abi_converter`: that of
# the compiled method of `f` for the types of the arguments, made when it is first needed, or if the method was changed since). The one that it has until then is a thunk
# (`j_N_gfthunk`) that boxes the arguments and calls `f` by dispatch (`ijl_apply_generic`). A program has neither of them. The method that the thunk calls is
# made part of the program by the code that cfunctions.jl adds (a function `cfunction_target_ID` for each `@cfunction`, that is called from the entry point where
# it can't be reached, so that it is compiled), and here the wrapper is made to call it: that is a call of the types that the wrapper has, which are those of C.

# What a `@cfunction` of the program is: the type of the function, the types of the arguments, and of the result, and the number that its function has
struct CFunctionRoot
    id::Int
    ftype::DataType
    args::Vector{DataType}
    ret::DataType
end
const CFUNCTION_ROOTS = CFunctionRoot[]

# the name of the function of the program that a root is compiled as (the compiler adds `julia_` and a number)
cfunction_root_name(id::Integer) = string("cfunction_target_", id)

# The function that a thunk of `jl_get_abi_converter` calls by dispatch: the roots that are for the type of its function, and have the types that it has
function cfunction_root_function(mod::LLVM.Module, thunk::LLVM.Function)
    fns = LLVM.functions(mod)
    haskey(fns, "ijl_apply_generic") || return nothing
    for use in LLVM.uses(fns["ijl_apply_generic"])
        call = LLVM.user(use)
        call isa LLVM.CallInst && LLVM.parent(LLVM.parent(call)) == thunk || continue
        addr = constant_object_address(LLVM.operands(call)[1])
        addr === nothing && return nothing
        is_process_address(addr) || return nothing
        ft = typeof(unsafe_pointer_to_objref(Ptr{Cvoid}(addr)))
        wanted = (string.(LLVM.parameters(LLVM.function_type(thunk))), string(LLVM.return_type(LLVM.function_type(thunk))))
        for root in CFUNCTION_ROOTS
            root.ftype === ft || continue
            prefix = string("julia_", cfunction_root_name(root.id), "_")
            for fn in values(fns)
                startswith(LLVM.name(fn), prefix) && !LLVM.isdeclaration(fn) || continue
                t = LLVM.function_type(fn)
                (string.(LLVM.parameters(t)), string(LLVM.return_type(t))) == wanted && return fn
            end
        end
    end
    return nothing
end

# A function of the type and the properties of `old` that calls `target` with its arguments, and is what `old` was: it has the name, and what used it uses it
function replace_with_call!(old::LLVM.Function, target::LLVM.Function)
    mod = LLVM.parent(old)
    t = LLVM.function_type(old)
    new = LLVM.Function(mod, "", t)
    LLVM.linkage!(new, LLVM.linkage(old))
    LLVM.visibility!(new, LLVM.visibility(old))
    LLVM.callconv!(new, LLVM.callconv(old))
    for attr in LLVM.function_attributes(old)
        push!(LLVM.function_attributes(new), attr)
    end
    for i in eachindex(LLVM.parameters(t))
        for attr in LLVM.parameter_attributes(old)[i]
            push!(LLVM.parameter_attributes(new)[i], attr)
        end
    end
    @dispose builder = LLVM.IRBuilder() begin
        LLVM.position!(builder, LLVM.at_end(LLVM.BasicBlock(new, "entry")))
        call = LLVM.call!(builder, LLVM.function_type(target), target, collect(LLVM.parameters(new)))
        LLVM.callconv!(call, LLVM.callconv(target))
        for i in eachindex(LLVM.parameters(t))
            for attr in LLVM.parameter_attributes(target)[i]
                LLVM.API.LLVMAddCallSiteAttribute(call, UInt32(i), attr)
            end
        end
        if LLVM.return_type(t) == LLVM.VoidType()
            LLVM.ret!(builder)
        else
            LLVM.ret!(builder, call)
        end
    end
    name = LLVM.name(old)
    LLVM.replace_uses!(old, new)
    LLVM.erase!(old)
    LLVM.name!(new, name)
    return new
end

# Make the wrappers of the `@cfunction`s call the functions of the program
function link_cfunctions!(mod::LLVM.Module)
    isempty(CFUNCTION_ROOTS) && return false
    fns = LLVM.functions(mod)
    haskey(fns, "jl_get_abi_converter") || return false
    wrappers = Dict{LLVM.Function,LLVM.Function}() # (the wrapper => the thunk that it has)
    for use in collect(LLVM.uses(fns["jl_get_abi_converter"]))
        call = LLVM.user(use)
        call isa LLVM.CallInst || continue
        wrapper = LLVM.parent(LLVM.parent(call))
        table = LLVM.operands(call)[2]
        table isa LLVM.GlobalVariable && LLVM.initializer(table) !== nothing || continue
        first = LLVM.operands(LLVM.initializer(table))[1]
        first isa LLVM.Function && (wrappers[wrapper] = first)
    end
    changed = false
    for (wrapper, thunk) in wrappers
        root = cfunction_root_function(mod, thunk)
        root === nothing && continue
        replace_with_call!(wrapper, root)
        changed = true
    end
    return changed
end
