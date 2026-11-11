# A minimal, libjulia-free runtime for statically compiled code, which is installed in the code
# that StaticCompiler generates by `link_runtime!` (see `llvm_postprocess` in `overrides.jl`).
#
# GPUCompiler lowers most of the Julia runtime interface to a small set of hooks
# (`gpu_gc_pool_alloc`, ...), but StaticCompiler compiles with `libraries=false`, so nothing
# defines them, and some other intrinsics (GC frames, `jl_alloc_genericmemory_unchecked`, ...)
# are left untouched. We define all of those here, so that code which allocates (`Vector`,
# `Dict`, `String`, boxes, closures, ...) links to a standalone binary.
#
# Policy: there is no garbage collector. Allocation is `malloc`/`calloc` and memory is never
# freed unless the program manages it itself (see `StaticTools.MallocArray`, Bumper, ...).

module Runtime

import StaticCompiler
using LLVM: LLVM, @dispose, run!
using LLVM.Passes: GlobalDCEPass
using StaticCompiler: isinttoptr, constant_address # from the pointer check

export link_runtime!, UnsupportedCodeError

# LLVM helpers

# The text of a constant C string global, or `nothing`
function constant_cstring(g)
    g isa LLVM.GlobalVariable || return nothing
    init = LLVM.initializer(g)
    init isa LLVM.ConstantDataArray || return nothing
    bytes = UInt8[convert(Int, e) for e in init.elements]
    return String(bytes[1:something(findfirst(==(0x00), bytes), length(bytes) + 1) - 1])
end

# The function `name` of the module, declared (with the type `ftype`) if the module does not have it yet
function declare!(mod::LLVM.Module, name::AbstractString, ftype::LLVM.FunctionType)
    fns = LLVM.functions(mod)
    return haskey(fns, name) ? fns[name] : LLVM.Function(mod, name, ftype)
end

# `puts(message); exit(1)` at the position of `builder`: what a program says when it reaches what it can't do. `message` is the text, or a pointer to a C string.
function abort_message!(builder::LLVM.IRBuilder, mod::LLVM.Module, message)
    puts_t = LLVM.FunctionType(LLVM.Int32Type(), [LLVM.PointerType()])
    exit_t = LLVM.FunctionType(LLVM.VoidType(), [LLVM.Int32Type()])
    text = message isa AbstractString ? LLVM.globalstring_ptr!(builder, message) : message
    LLVM.call!(builder, puts_t, declare!(mod, "puts", puts_t), [text])
    LLVM.call!(builder, exit_t, declare!(mod, "exit", exit_t), [LLVM.ConstantInt(Int32(1))])
    return
end

include("heap.jl")        # the allocator and the collector, in Julia (compiled into the program)
include("shims.jl")       # the runtime in LLVM IR, and the functions that a program may call
include("strict.jl")      # what is refused, and what aborts
include("objects.jl")     # the objects of this process, as they are in memory
include("embedder.jl")    # copying them into the binary
include("constants.jl")   # finding the constants of a module, and embedding them
include("types.jl")       # `getfield`, `<:` and `isa` at run time
include("heap_link.jl")   # allocation and the collector, linked
include("blas.jl")        # BLAS and LAPACK, through libblastrampoline
include("loader.jl")      # the functions of libraries, found when the program needs them
include("libraries.jl")   # the functions of libraries that are called by their library: libm, and the others loaded when the program runs
include("cfunctions_link.jl") # the wrappers of `@cfunction`, that call the functions of the program

# Define the runtime functions that `mod` calls but does not define.
function link_runtime!(mod::LLVM.Module; strict::Bool = true, allow = (), gc = Sys.isapple() || Sys.islinux(), libraries::Symbol = :system, bounded::Bool = false)
    link_cfunctions!(mod) && run!(GlobalDCEPass(), mod)
    blas = resolve_blas_lookups!(mod) # (before what they are given is embedded)
    library_plan = resolve_library_lookups!(mod; libraries)
    drop_ignorable_calls!(mod)
    define_field_index!(mod)
    define_subtype_builtins!(mod)
    null_methoderror_arguments!(mod)
    stub_cancel_handlers!(mod)
    e = ObjectEmbedder(mod, Dict())
    define_well_known_objects!(e)
    lower_gc_frames!(mod)
    gc === false || classify_allocations!(mod)
    queries = subtype_queries(mod)
    embed_constants!(e)
    queries === nothing ? define_subtype_table!(e) : define_subtype!(e, queries)
    finalizers = uses_finalizers(mod) # (before they are linked: see `link_finalizers!`)
    link_finalizers!(mod)
    resolve_lazy_lookups!(mod)
    define_aborting_functions!(mod)
    if strict
        dynamic = dynamic_runtime_calls(mod; allow)
        pointers = unresolved_pointer_uses(mod)
        isempty(dynamic) && isempty(pointers) || throw(UnsupportedCodeError(dynamic, pointers, isempty(dynamic) ? String[] : nonconst_globals(mod)))
    end
    define_dynamic_stubs!(mod)
    needed = filter(RUNTIME_SHIM_FUNCTIONS) do name
        haskey(LLVM.functions(mod), name) && LLVM.isdeclaration(LLVM.functions(mod)[name])
    end
    linked = !isempty(needed)
    if linked
        well_known_object!(e, "jl_nothing", nothing) # (the shim refers to it, from the task)
        shim = parse(LLVM.Module, shim_ir())
        LLVM.datalayout!(shim, LLVM.datalayout(mod))
        LLVM.triple!(shim, LLVM.triple(mod))
        LLVM.link!(mod, shim) # consumes `shim`
    end
    linked |= link_blas!(mod, blas)
    linked |= link_libraries!(mod, library_plan; libraries)
    if gc === true && !finalizers && haskey(LLVM.functions(mod), "static_alloc")
        run!(GlobalDCEPass(), mod) # (what the program does not use does not count)
        allocation_is_finite(mod; bounded) && (gc = false)
    end
    linked |= link_heap!(mod; gc, finalizers) # (the shim, and the code, call `static_alloc`)
    haskey(LLVM.functions(mod), "gpu_gc_pool_alloc") && inline_allocation!(mod, gc)
    linked && run!(GlobalDCEPass(), mod)
    return mod
end

end # module Runtime
