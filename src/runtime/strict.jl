# Strict mode: what a program that needs libjulia (or the addresses of objects of the process that compiled it) is refused with, and what it does if it is compiled anyway (`strict = false`):
# calls that abort, with a message that says what could not be done.

# Runtime functions that throw. Without unwinding, the best we can do is to report and exit.
# Their bodies are generated from the declaration, since we don't care about the arguments.
const ABORTING_RUNTIME_FUNCTIONS = (
    "ijl_bounds_error_int" => "BoundsError: index out of bounds",
    "ijl_bounds_error_unboxed_int" => "BoundsError: index out of bounds",
    "ijl_bounds_error" => "BoundsError: index out of bounds",
    "ijl_type_error" => "TypeError: type assertion failed",
    "ijl_undefined_var_error" => "UndefVarError: undefined variable",
    "jl_f_throw_methoderror" => "MethodError: no matching method",
    "ijl_has_no_field_error" => "ErrorException: type has no field",
)

# Runtime functions for dynamic behavior (dispatch on types only known at run time, ...), which
# a standalone binary can't provide. Code that calls them is rejected (`UnsupportedCodeError`)
# unless compiled with `strict = false`; they are then defined to abort if one is reached, which is
# often fine, as they typically sit on cold paths, e.g. building the message of an error.
const DYNAMIC_RUNTIME_FUNCTIONS = [
    name => "Dynamic behavior is not supported in standalone binaries ($name)" for name in (
        "ijl_apply_generic", "jl_apply_generic", "jl_f__apply_iterate", "jl_f_apply_type",
        "ijl_get_nth_field_checked", "jl_f_fieldtype", "jl_f_tuple", "ijl_new_structv",
        "jl_f__task", "jl_f__svec_ref", "ijl_subtype",
        "ijl_object_id_", "jl_object_id_", "ijl_object_id", "jl_object_id", "jl_get_abi_converter", "ijl_load_and_lookup", "ijl_lazy_load_and_lookup", "jl_f_getfield",
        "jl_f_typeassert", "ijl_new_task",
    )
]

# Give the body `puts(msg); exit(1)` to the declaration `fn`
function define_aborting!(mod::LLVM.Module, fn::LLVM.Function, msg::AbstractString)
    LLVM.linkage!(fn, LLVM.API.LLVMLinkOnceODRLinkage)
    @dispose builder = LLVM.IRBuilder() begin
        LLVM.position!(builder, LLVM.at_end(LLVM.BasicBlock(fn, "entry")))
        abort_message!(builder, mod, msg)
        LLVM.unreachable!(builder)
    end
    return
end

# Calls of runtime functions that have nothing to do in a program, and are dropped (instead of refusing the code that has them):
# * the construction of an `Expr` whose result is not used (`Expr(:meta, :noinline)` is written as a statement in some packages, as a hint that Julia reads from the code, and is not removed
#   when it is compiled);
# * the warning about a deprecated binding (`Base.@deprecate_binding`), which like `Base.depwarn` (see `src/overrides/base.jl`) is not shown by a program.
const DROPPED_WHEN_UNUSED = ("jl_f__expr", "ijl_f__expr")
const DROPPED_ALWAYS = ("jl_binding_depwarn", "ijl_binding_depwarn")

function drop_ignorable_calls!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    dead = LLVM.Instruction[]
    for (names, only_unused) in ((DROPPED_WHEN_UNUSED, true), (DROPPED_ALWAYS, false)), name in names
        haskey(fns, name) || continue
        for use in LLVM.uses(fns[name])
            call = LLVM.user(use)
            call isa LLVM.CallInst || continue
            only_unused && !isempty(collect(LLVM.uses(call))) && continue
            push!(dead, call)
        end
    end
    for call in dead
        LLVM.erase!(call)
    end
    return !isempty(dead)
end

# the Julia function that an instruction belongs to, as a readable name
function function_of(inst::LLVM.Instruction)
    name = LLVM.name(LLVM.parent(LLVM.parent(inst)))
    name = replace(name, r"^julia_" => "", r"_\d+$" => "")
    return name
end

# Runtime functions for errors, which are reported by aborting. The bodies are generated from the
# declaration, since we don't care about the arguments.
function define_aborting_functions!(mod::LLVM.Module)
    changed = false
    fns = LLVM.functions(mod)
    for (name, msg) in ABORTING_RUNTIME_FUNCTIONS
        haskey(fns, name) && LLVM.isdeclaration(fns[name]) || continue
        define_aborting!(mod, fns[name], msg)
        changed = true
    end
    return changed
end

"""
    UnsupportedCodeError

The code that was compiled contains things that cannot work in a standalone binary: calls that
need the Julia runtime (such as dynamic dispatch), or references to Julia objects by address. They
would crash the program, or abort it if they are reached. Compile with `strict = false` to
allow these (see `compile_executable`), or `allow = (...)` to allow specific runtime functions.
"""
struct UnsupportedCodeError <: Exception
    dynamic::Vector{Pair{String,Vector{String}}} # runtime function => where it is called from
    pointers::Vector{Tuple{String,String}}       # (function, instruction) that use an address
    globals::Vector{String}                      # the global variables that are not `const` that the code uses (a likely cause of types that are not known)
end

UnsupportedCodeError(dynamic, pointers) = UnsupportedCodeError(dynamic, pointers, String[])

# the names (with their modules) of the global variables that are not `const` that the code reads or writes: their bindings are in the binary
function nonconst_globals(mod::LLVM.Module)
    names = String[]
    for g in LLVM.globals(mod)
        name = LLVM.name(g)
        startswith(name, "static_object_") || continue
        addr = tryparse(UInt, first(split(name[15:end], '.')), base = 16)
        (addr === nothing || object_type(addr) !== Core.Binding) && continue
        ref = unsafe_pointer_to_objref(Ptr{Cvoid}(addr)).globalref
        ref isa GlobalRef && !isconst(ref.mod, ref.name) && push!(names, string(ref.mod, ".", ref.name))
    end
    return sort!(unique!(names))
end

function Base.showerror(io::IO, e::UnsupportedCodeError)
    print(io, "UnsupportedCodeError: the code cannot run as a standalone binary")
    if !isempty(e.dynamic)
        print(io, "\n\nIt needs the Julia runtime (e.g. for dynamic dispatch, which means that the types in some call are not known at compile time):")
        for (name, callers) in e.dynamic
            print(io, "\n  ", name, ", called from ", join(first(callers, 5), ", "), length(callers) > 5 ? ", ..." : "")
        end
    end
    if !isempty(e.pointers)
        print(io, "\n\nIt refers to Julia objects by their address in this process, which are not in the binary:")
        for (fn, inst) in first(e.pointers, 5)
            print(io, "\n  in ", fn, ": ", strip(inst))
        end
        length(e.pointers) > 5 && print(io, "\n  ... and ", length(e.pointers) - 5, " more")
    end
    # hints for what is likely to be the cause
    if any(((_, inst),) -> occursin(r"%(stdout|stderr|stdin)\b", inst), e.pointers) ||
       any(((name, callers),) -> any(c -> c in ("print", "println", "format"), callers) && name == "ijl_apply_generic", e.dynamic)
        print(io, "\n\nHint: `stdout`, `stderr` and `stdin` of Base are globals of the abstract type `IO`, so what is done with them cannot be resolved when compiling. ",
              "Use `print`, `println` and `show` without an `IO` (which write to the standard output), or `STDOUT`, `STDERR` and `STDIN` of StaticCompilerOverrides, as in `println(STDERR, \"message\")`. ",
              "For `@printf`, which uses `stdout` if it has no `io`: `@printf(STDOUT, \"...\", x)`, or `printf(c\"...\", x)` of StaticTools.")
    end
    if !isempty(e.globals) && !isempty(e.dynamic)
        print(io, "\n\nHint: the code uses global variables that are not `const` (", join(string.("`", e.globals, "`"), ", "), "). An untyped global of that kind can hold a value of ",
              "any type, which is only known when the program runs, so a call on it can't be resolved when compiling. Make it `const` (`const x = ...`; a `Ref` or a container ",
              "can still be changed), or give it a type (`x::Vector{Int} = ...`: then a read of it is known to be of that type, and it can be assigned).")
    end
    print(io, "\n\nPass `strict = false` to compile it anyway: calls that need the runtime will then abort the program if they are reached, and the addresses will crash it.")
    print(io, " Use `allow = (\"function_name\", ...)` to allow specific runtime functions only.")
end

# The calls (and the functions they are in) to the runtime functions that need dynamic behavior,
# which a standalone binary cannot provide. These are the declarations in `mod` that are used.
function dynamic_runtime_calls(mod::LLVM.Module; allow = ())
    found = Pair{String,Vector{String}}[]
    fns = LLVM.functions(mod)
    for (name, _) in DYNAMIC_RUNTIME_FUNCTIONS
        haskey(fns, name) && LLVM.isdeclaration(fns[name]) || continue
        name in allow && continue
        callers = String[]
        for use in LLVM.uses(fns[name])
            inst = LLVM.user(use)
            inst isa LLVM.Instruction || continue
            what = function_of(inst)
            # a `ccall` into a library that we couldn't resolve: say which function
            if inst isa LLVM.CallInst && name in ("ijl_load_and_lookup", "ijl_lazy_load_and_lookup")
                sym = constant_cstring(LLVM.operands(inst)[2])
                sym === nothing || (what = "$what (ccall to `$sym`)")
            end
            what in callers || push!(callers, what)
        end
        isempty(callers) || push!(found, name => callers)
    end
    # any other function of libjulia that is called, and that nothing here defines, is not in the binary either
    for fn in fns
        name = LLVM.name(fn)
        is_libjulia_function(name) && LLVM.isdeclaration(fn) && !isempty(LLVM.uses(fn)) || continue
        (name in allow || name in RUNTIME_SHIM_FUNCTIONS || any(==(name) ∘ first, DYNAMIC_RUNTIME_FUNCTIONS)) && continue
        callers = String[]
        for use in LLVM.uses(fn)
            inst = LLVM.user(use)
            inst isa LLVM.Instruction || continue
            what = function_of(inst)
            what in callers || push!(callers, what)
        end
        isempty(callers) || push!(found, name => callers)
    end
    return found
end

# the names of the functions of libjulia (`ijl_` and `jl_`, but not the intrinsics of Julia's code generator, which are `julia.`)
is_libjulia_function(name::AbstractString) = startswith(name, "ijl_") || startswith(name, "jl_")

# Define the runtime functions for dynamic behavior as ones that abort, as the ones that are
# still used, which is what happens if `strict = false`.
function define_dynamic_stubs!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    for (name, msg) in DYNAMIC_RUNTIME_FUNCTIONS
        haskey(fns, name) && LLVM.isdeclaration(fns[name]) || continue
        isempty(LLVM.uses(fns[name])) && continue
        @debug "Code calls a runtime function that is not supported, and will abort if it is reached" name
        define_aborting!(mod, fns[name], msg)
    end
    for fn in collect(fns) # (any other function of libjulia: see `dynamic_runtime_calls`)
        name = LLVM.name(fn)
        is_libjulia_function(name) && LLVM.isdeclaration(fn) && !isempty(LLVM.uses(fn)) || continue
        name in RUNTIME_SHIM_FUNCTIONS && continue
        @debug "Code calls a function of libjulia that is not in the binary, and will abort if it is reached" name
        define_aborting!(mod, fn, "Dynamic behavior is not supported in standalone binaries ($name)")
    end
end

# Runtime functions that are given pointers to objects (types, exceptions) which they don't look into
const POINTER_ARGUMENTS_NOT_USED = Set([
    "jl_alloc_genericmemory_unchecked", "ijl_alloc_genericmemory_unchecked", "ijl_type_error",
    "ijl_undefined_var_error", "ijl_bounds_error_int", "ijl_bounds_error_unboxed_int", "ijl_bounds_error",
    "ijl_throw", "ijl_rethrow_other", "jl_argument_error", "gpu_unsupported_allocation",
    "julia.gc_alloc_bytes", "jl_f_throw_methoderror", "ijl_enter_handler", "ijl_pop_handler",
    "ijl_pop_handler_noexcept", "ijl_excstack_state", "ijl_restore_excstack",
])

# The places where code reads, writes or calls through a pointer to a Julia object that is not
# in the binary (an address from this process): these are certain to crash. Comparing such a
# pointer is common (type tags) and fine; passing it as an argument is too only to a few functions.
function unresolved_pointer_uses(mod::LLVM.Module)
    found = Tuple{String,String}[]
    seen = Set{Tuple{String,UInt}}()
    for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
        ops = if inst isa LLVM.LoadInst
            (LLVM.operands(inst)[1],)
        elseif inst isa LLVM.StoreInst
            Tuple(LLVM.operands(inst)[1:2])
        elseif inst isa LLVM.CallInst
            callee = LLVM.called_operand(inst)
            # the arguments too, unless the function only takes a pointer to something that
            # describes a type, or an error: those are not looked into
            name = callee isa LLVM.Function ? LLVM.name(callee) : ""
            name in POINTER_ARGUMENTS_NOT_USED ? (callee,) : (callee, LLVM.arguments(inst)...)
        elseif inst isa LLVM.GetElementPtrInst
            (LLVM.operands(inst)[1],)
        elseif inst isa LLVM.ICmpInst
            LLVM.operands(inst) # (a type compared by the number of its address: see `type_number_constants`)
        else
            ()
        end
        for op in ops
            addr = if op isa LLVM.ConstantExpr && isinttoptr(op) && !(inst isa LLVM.ICmpInst) # (a comparison of pointers: numbers)
                constant_address(op)
            elseif op isa LLVM.ConstantInt && inst isa LLVM.ICmpInst && LLVM.width(LLVM.value_type(op)) == 64
                n = convert(UInt, op)
                n >= 0x10000 && n % 16 == 0 && object_type(n) === DataType ? n : nothing
            elseif op isa LLVM.ConstantInt && inst isa LLVM.CallInst && LLVM.width(LLVM.value_type(op)) == 64
                # an address that is passed as a number (see `embed_address_arguments!`), if it is that of an object, and is not used as data
                n = convert(UInt, op)
                args = LLVM.arguments(inst)
                used_as_address = any(i -> args[i] == op && !integer_operand_is_data(inst, i), eachindex(args))
                n >= 0x10000 && used_as_address && !isempty(address_argument_objects(n)) ? n : nothing
            else
                nothing
            end
            (addr === nothing || addr < 0x10000) && continue
            key = (LLVM.name(fn), UInt(addr))
            key in seen && continue
            push!(seen, key)
            push!(found, (function_of(inst), string(inst)))
        end
    end
    return found
end
