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
function link_runtime!(mod::LLVM.Module; strict::Bool = true, stub_errors::Bool = true, allow = (), gc = Sys.isapple() || Sys.islinux() ? :auto : false, libraries::Symbol = :system, bounded::Bool = false, optimize::Bool = false)
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
    drop_invariant_root_loads!(mod) # (the slots of the frames are written after they are zeroed: see there)
    gc === false || classify_allocations!(mod)
    queries = subtype_queries(mod)
    embed_constants!(e)
    queries === nothing ? define_subtype_table!(e) : define_subtype!(e, queries)
    finalizers = uses_finalizers(mod) # (before they are linked: see `link_finalizers!`)
    link_finalizers!(mod)
    resolve_lazy_lookups!(mod)
    define_aborting_functions!(mod)
    if stub_errors
        stubbed = stub_error_paths!(mod; allow)
        isempty(stubbed) || @debug "Code that needs the Julia runtime, and is only on the way to an error, was replaced by a stop with a message" count = length(stubbed) first = first(stubbed, 5) _id = :static_error_paths
    end
    if strict
        dynamic = dynamic_runtime_calls(mod; allow)
        pointers = unresolved_pointer_uses(mod)
        isempty(dynamic) && isempty(pointers) || throw(UnsupportedCodeError(dynamic, pointers, isempty(dynamic) ? String[] : nonconst_globals(mod), dynamic_call_sites(mod, dynamic)))
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
    if gc === :auto # (the collector is in the program if it needs it: if something that it allocates is not allocated a finite number of times, or it has finalizers)
        gc = true
        if !finalizers && haskey(LLVM.functions(mod), "static_alloc")
            run!(GlobalDCEPass(), mod) # (what the program does not use does not count)
            allocation_is_finite(mod; bounded) && (gc = false)
        end
    end
    linked |= link_heap!(mod; gc, finalizers) # (the shim, and the code, call `static_alloc`)
    haskey(LLVM.functions(mod), "gpu_gc_pool_alloc") && inline_allocation!(mod, gc)
    linked && run!(GlobalDCEPass(), mod)
    inline_internal_functions!(mod; optimize)
    return mod
end

# The functions of the program are internal to it when this runs, and not when they were optimized (they are exported by the module of StaticCompiler until it is done): a function that is called from one
# place was then not inlined, whatever its size, and what is made of calls to it (`pow`, which calls the function of the logarithm and gets two numbers back through memory) was up to twice as slow as in Julia.
# The inliner is run again, for the functions that are now local (`noinline` and the functions that call `sigsetjmp` are not inlined by it). With `optimize = true` the optimizer's pipeline (`O2`) is run on the whole module as well, which has
# what it could not do before: the functions that are local can have their arguments and results changed, and what is known of the calls of the runtime (the allocator) is used. (`fib` is 30% faster, the allocation of
# the binary trees 4%, and the strings of the string program 9%: the code of a math function can be 8% slower; see the benchmarks in the manual.) It is not the default: on CI, programs that crashed on Linux (`rand(Int)`), added up
# `Float16` in another order than Julia does, and had more of the raw pointers that StaticCompiler warns about, with it. It needs `drop_invariant_root_loads!` and `drop_type_based_aliasing!`: see there.
# Type-based aliasing information (`!tbaa`) says which loads and stores cannot be of the same memory. In Julia's IR it is true, and the passes that ran on it used it. It is not after the inliner and the passes that
# follow it have changed that IR: a load of an immutable tuple (`jtbaa_const`) of a copy that a `memcpy` made (`jtbaa_field`) was taken to be of memory that nothing wrote, which is `undef`, and `GVN` made
# of `dynamic_width || dynamic_precision`, of the `@printf` of two things into a file, `true`. The aliasing is dropped before the pipeline (the information of scopes, `!alias.scope` and `!noalias`, is kept).
function drop_type_based_aliasing!(mod::LLVM.Module)
    ctx = LLVM.context(mod)
    ids = [LLVM.API.LLVMGetMDKindIDInContext(ctx, k, length(k)) for k in ("tbaa", "tbaa.struct")]
    for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb), id in ids
        LLVM.API.LLVMSetMetadata(inst, id, C_NULL)
    end
    return
end

# The functions that are rarely run: what is known to be so is the code on the way to an error (see `error_functions`), and the functions that Julia marks `cold` (the constructors of the exceptions,
# what throws) or `noreturn`, with those that are only called from them. A path that is rarely run and returns is not here (it can be that, and not an error): this is what is known, and not all that is cold.
function cold_functions(mod::LLVM.Module)
    marked = Set{LLVM.Function}(fn for fn in LLVM.functions(mod) if !LLVM.isdeclaration(fn) &&
                                any(a -> a in collect(LLVM.function_attributes(fn)), (LLVM.EnumAttribute("cold"), LLVM.EnumAttribute("noreturn"))))
    return error_functions(mod, Dict{LLVM.Function,Set{LLVM.BasicBlock}}(); seeds = marked)
end

# The code that is rarely run is optimized for size (`optsize` and `minsize`, as `-Oz` does): the code that runs only to stop with an error is 10% of the code of a program that prints, parses or sorts, and nothing
# waits for it. (The machine outliner of AArch64 runs on the functions that are `minsize`.) The rest of the program is not: the same for all of it takes 12 to 34% more time.
function optimize_cold_for_size!(mod::LLVM.Module)
    cold = cold_functions(mod)
    for fn in LLVM.functions(mod)
        LLVM.isdeclaration(fn) && continue
        fn in cold || continue
        push!(LLVM.function_attributes(fn), LLVM.EnumAttribute("optsize"))
        push!(LLVM.function_attributes(fn), LLVM.EnumAttribute("minsize"))
    end
    return
end

function inline_internal_functions!(mod::LLVM.Module; optimize::Bool = false)
    # Only the functions that are internal: the others (`static_alloc` of the heap, the loader of BLAS, ...) are the runtime, which is called and was not inlined before; inlining
    # `static_alloc` into every allocation of a program, with its slow paths, made programs crash (the one that calls BLAS, on the machines of CI).
    kept = LLVM.Function[]
    noinline = LLVM.EnumAttribute("noinline")
    for fn in LLVM.functions(mod)
        LLVM.isdeclaration(fn) && continue
        LLVM.linkage(fn) in (LLVM.API.LLVMInternalLinkage, LLVM.API.LLVMPrivateLinkage) && continue
        any(==(noinline), collect(LLVM.function_attributes(fn))) && continue
        push!(LLVM.function_attributes(fn), noinline)
        push!(kept, fn)
    end
    try
        run!("cgscc(inline),function(sroa,instcombine<no-verify-fixpoint>,simplifycfg)", mod)
    finally
        for fn in kept
            delete!(LLVM.function_attributes(fn), noinline)
        end
    end
    run!(GlobalDCEPass(), mod)
    optimize_cold_for_size!(mod)
    if optimize
        drop_type_based_aliasing!(mod)
        run!("default<O2>", mod)
        run!(GlobalDCEPass(), mod)
    end
    return
end

end # module Runtime
