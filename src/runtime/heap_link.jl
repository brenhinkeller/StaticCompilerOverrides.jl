# Linking the heap: the allocations of the program become calls of the allocator (and the collector), its roots are the objects that are copied into the binary, and the program has
# the functions that run the finalizers (see `finalizers.jl`). The allocator itself is `heap.jl`.

# Replace Julia's GC frame intrinsics (which have no runtime without a GC) by plain stack slots.
function lower_gc_frames!(mod::LLVM.Module)
    haskey(LLVM.functions(mod), "julia.new_gc_frame") || return false
    changed = false
    ptrT = LLVM.PointerType()
    @dispose builder=LLVM.IRBuilder() begin
        # slots first (they use the frame), then the frame itself
        if haskey(LLVM.functions(mod), "julia.get_gc_frame_slot")
            f = LLVM.functions(mod)["julia.get_gc_frame_slot"]
            for use in collect(LLVM.uses(f))
                call = LLVM.user(use)::LLVM.CallInst
                frame, idx = LLVM.operands(call)[1], LLVM.operands(call)[2]
                LLVM.position!(builder, LLVM.before(call))
                slot = LLVM.gep!(builder, ptrT, frame, [idx])
                LLVM.replace_uses!(call, slot)
                LLVM.erase!(call)
                changed = true
            end
        end
        for name in ("julia.push_gc_frame", "julia.pop_gc_frame")
            haskey(LLVM.functions(mod), name) || continue
            for use in collect(LLVM.uses(LLVM.functions(mod)[name]))
                LLVM.erase!(LLVM.user(use)::LLVM.CallInst)
                changed = true
            end
        end
        f = LLVM.functions(mod)["julia.new_gc_frame"]
        for use in collect(LLVM.uses(f))
            call = LLVM.user(use)::LLVM.CallInst
            n = LLVM.operands(call)[1]
            LLVM.position!(builder, LLVM.before(call))
            frame = LLVM.array_alloca!(builder, ptrT, n, "gcframe")
            # zero it, as a GC frame would expect
            sz = LLVM.mul!(builder, LLVM.zext!(builder, n, LLVM.Int64Type()), LLVM.ConstantInt(Int64(sizeof(Ptr))))
            LLVM.call!(builder, LLVM.FunctionType(LLVM.VoidType(), [ptrT, LLVM.Int8Type(), LLVM.Int64Type(), LLVM.Int1Type()]),
                  LLVM.Function(mod, "llvm.memset.p0.i64", LLVM.FunctionType(LLVM.VoidType(), [ptrT, LLVM.Int8Type(), LLVM.Int64Type(), LLVM.Int1Type()])),
                  [frame, LLVM.ConstantInt(UInt8(0)), sz, LLVM.ConstantInt(LLVM.Int1Type(), 0)])
            LLVM.replace_uses!(call, frame)
            LLVM.erase!(call)
            changed = true
        end
    end
    return changed
end

# The allocation functions are small and called from everywhere, and nothing optimizes the module after this: they are
# inlined where they are called
# The allocation functions are small and called from everywhere, and nothing optimizes the module after this: they are
# inlined where they are called (the allocator itself too, without the collector: it is a few instructions)
const INLINED_ALLOCATORS = ("gpu_gc_pool_alloc", "gpu_gc_pool_alloc_atomic", "julia.gc_alloc_bytes", "jl_alloc_genericmemory_unchecked",
                            "jl_alloc_genericmemory_atomic", "ijl_alloc_string")

function inline_allocation!(mod::LLVM.Module, gc)
    fns = LLVM.functions(mod)
    names = gc === false ? [INLINED_ALLOCATORS..., "static_alloc"] : collect(INLINED_ALLOCATORS)
    for name in names
        haskey(fns, name) && !LLVM.isdeclaration(fns[name]) || continue
        push!(LLVM.function_attributes(fns[name]), LLVM.EnumAttribute("alwaysinline"))
    end
    run!(LLVM.Passes.AlwaysInlinerPass(), mod)
    return
end

# Whether the objects of the concrete type `T` have no references to other objects: the collector doesn't look inside the
# objects that can't, and so a type that is one by mistake would have what it refers to freed. (A `Memory` of elements
# stored inline that are plain data: it has a pointer, to its own data; objects with a Union of such, which are a few
# bytes more, are not claimed to be.)
function type_pointerfree(T)
    T isa DataType && isconcretetype(T) || return false
    if T <: Core.GenericMemory
        ET = eltype(T)
        return ET isa DataType && Base.allocatedinline(ET) && Base.datatype_pointerfree(ET)
    end
    return Base.datatype_pointerfree(T)
end

# Allocations of objects that can't refer to others are made as such (the collector doesn't look inside them): a call
# that is `julia.gc_alloc_bytes(ptls, size, type)` or `jl_alloc_genericmemory_unchecked(ptls, nbytes, type)` of a type that is a
# constant. (Those of `julia.gc_alloc_obj` are made so by the pass that tags them, which sees the type: see `src/tags.jl`.)
function classify_allocations!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    ptrT = LLVM.PointerType()
    i64T = LLVM.Int64Type()
    changed = false
    function replace_call!(call, callee_name, ftype, args)
        callee = declare!(mod, callee_name, ftype)
        @dispose builder = LLVM.IRBuilder() begin
            LLVM.position!(builder, LLVM.before(call))
            new = LLVM.call!(builder, ftype, callee, args)
            LLVM.replace_uses!(call, new)
            LLVM.erase!(call)
        end
        return
    end
    if haskey(fns, "julia.gc_alloc_bytes")
        for use in collect(LLVM.uses(fns["julia.gc_alloc_bytes"]))
            call = LLVM.user(use)
            call isa LLVM.CallInst || continue
            tag = LLVM.operands(call)[3]
            tag isa LLVM.ConstantInt || continue
            type_pointerfree(tag_type(UInt(convert(UInt64, tag)))) || continue
            replace_call!(call, "gpu_gc_pool_alloc_atomic", LLVM.FunctionType(ptrT, [i64T]), [LLVM.operands(call)[2]])
            changed = true
        end
    end
    if haskey(fns, "jl_alloc_genericmemory_unchecked")
        ftype = LLVM.function_type(fns["jl_alloc_genericmemory_unchecked"])
        for use in collect(LLVM.uses(fns["jl_alloc_genericmemory_unchecked"]))
            call = LLVM.user(use)
            call isa LLVM.CallInst || continue
            ops = LLVM.operands(call)
            addr = constant_object_address(ops[3])
            addr === nothing && continue
            object_type(addr) === DataType || continue
            type_pointerfree(unsafe_pointer_to_objref(Ptr{Cvoid}(addr))) || continue
            replace_call!(call, "jl_alloc_genericmemory_atomic", ftype, collect(ops)[1:end-1])
            changed = true
        end
    end
    return changed
end

# The heap (`heap.jl`) is Julia code, compiled with StaticCompiler the first time that it is needed in the session,
# and kept as IR: the module is made in the context that is active now (the one that the code that is compiled is
# in, which the module of the heap is linked into), so what is kept is its text. Its functions other than the one that
# the program calls, and its state, are internal to it, so that they can't clash with those of the program.
const HEAP_IR = Dict{Bool,String}()

function heap_ir(gc::Bool)
    haskey(HEAP_IR, gc) && return HEAP_IR[gc]
    alloc = gc ? Heap.alloc : Heap.alloc_nogc
    heap = StaticCompiler.compile_llvm_module(alloc, (Int, Int), "static_alloc")
    try
        for fn in LLVM.functions(heap)
            LLVM.isdeclaration(fn) || LLVM.name(fn) == "static_alloc" || LLVM.linkage!(fn, LLVM.API.LLVMInternalLinkage)
        end
        for g in LLVM.globals(heap)
            LLVM.isdeclaration(g) || LLVM.linkage!(g, LLVM.API.LLVMInternalLinkage)
        end
        HEAP_IR[gc] = string(heap)
    finally
        LLVM.dispose(heap)
    end
    return HEAP_IR[gc]
end

# What the collector looks at besides the stack: the data of the program that can refer to objects of the heap, which are
# the objects that were copied into the binary (a `const` that is a container may be changed to refer to anything) and the
# state of the runtime (the exceptions that are being handled); as { count, (address, bytes)... }
function define_gc_roots!(mod::LLVM.Module)
    dl = LLVM.datalayout(mod)
    words = LLVM.Constant[]
    for g in LLVM.globals(mod)
        # (`LLVM.isconstant` is whether it is an LLVM constant, which every global is: whether the program can change it is this)
        (LLVM.isdeclaration(g) || LLVM.API.LLVMIsGlobalConstant(g) != 0) && continue
        name = LLVM.name(g)
        (startswith(name, "static_object_") || startswith(name, "_static_") || startswith(name, "jl_global_")) || continue
        size = Int(LLVM.API.LLVMABISizeOfType(dl, LLVM.value_type(LLVM.initializer(g))))
        push!(words, LLVM.const_ptrtoint(g, LLVM.Int64Type()), LLVM.ConstantInt(Int64(size)))
    end
    table = LLVM.ConstantArray(LLVM.Int64Type(), LLVM.Constant[LLVM.ConstantInt(Int64(length(words) ÷ 2)), words...])
    g = LLVM.GlobalVariable(mod, LLVM.value_type(table), "_static_gc_roots")
    LLVM.initializer!(g, table)
    LLVM.constant!(g, true)
    LLVM.visibility!(g, LLVM.API.LLVMHiddenVisibility)
    return
end

# `gc` is `false` (memory is never freed), `true` (it is, by a collector), or a number of allocations (the collector
# also runs that often, which is for finding what it frees by mistake, and what is freed is overwritten); the heap reads
# this as a global that is always there (0 is not to), as a reference to a symbol that is not defined doesn't link
function define_gc_stress!(mod::LLVM.Module, interval::Integer)
    g = LLVM.GlobalVariable(mod, LLVM.Int64Type(), "_static_gc_stress")
    LLVM.initializer!(g, LLVM.ConstantInt(Int64(interval)))
    LLVM.constant!(g, true)
    LLVM.visibility!(g, LLVM.API.LLVMHiddenVisibility)
    return
end

# Define `static_alloc` (the allocation of the shim), if the code needs it; whether it did
function link_heap!(mod::LLVM.Module; gc = false)
    fns = LLVM.functions(mod)
    haskey(fns, "static_alloc") && LLVM.isdeclaration(fns["static_alloc"]) || return false
    collect_garbage = gc !== false
    if collect_garbage
        Sys.isapple() || Sys.islinux() || throw(ArgumentError("the garbage collector is not available on this system (use `gc = false`)"))
        define_gc_roots!(mod)
        define_gc_stress!(mod, !(gc isa Bool) && gc isa Integer && gc > 0 ? gc : 0) # (`true` is an `Integer` too)
        # (the heap refers to the function that runs finalizers: a program that has none gets one that does nothing, as a reference to a symbol that is not defined doesn't link)
        if !haskey(LLVM.functions(mod), "static_run_finalizer")
            f = LLVM.Function(mod, "static_run_finalizer", LLVM.FunctionType(LLVM.VoidType(), [LLVM.Int64Type(), LLVM.Int64Type()]))
            LLVM.@dispose builder = LLVM.IRBuilder() begin
                LLVM.position!(builder, LLVM.at_end(LLVM.BasicBlock(f, "entry")))
                LLVM.ret!(builder)
            end
        end
    end
    heap = parse(LLVM.Module, heap_ir(collect_garbage))
    LLVM.datalayout!(heap, LLVM.datalayout(mod))
    LLVM.triple!(heap, LLVM.triple(mod))
    LLVM.link!(mod, heap) # consumes `heap`
    return true
end

# The function that runs the finalizers of the program (see `finalizers.jl`): `static_run_finalizer(site, object)`, a `switch` on the number of the site that
# calls the function of each. The functions are found by the marker that they have in them (`static_finalizer_marker(number)`), which is taken out.
function link_finalizers!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "static_finalizer_marker") || return false
    marker = fns["static_finalizer_marker"]
    runners = Tuple{Int,LLVM.Function}[]
    for use in collect(LLVM.uses(marker))
        call = LLVM.user(use)
        call isa LLVM.CallInst || continue
        id = convert(Int, LLVM.operands(call)[1])
        push!(runners, (id, LLVM.parent(LLVM.parent(call))))
        LLVM.erase!(call)
    end
    LLVM.erase!(marker)
    i64 = LLVM.Int64Type()
    isempty(runners) && return false
    LLVM.@dispose builder = LLVM.IRBuilder() begin
        fty = LLVM.FunctionType(LLVM.VoidType(), [i64, i64])
        f = declare!(mod, "static_run_finalizer", fty)
        LLVM.isdeclaration(f) || return true
        entry = LLVM.BasicBlock(f, "entry")
        done = LLVM.BasicBlock(f, "done")
        LLVM.position!(builder, LLVM.at_end(entry))
        sw = LLVM.switch!(builder, LLVM.parameters(f)[1], done, length(runners))
        for (id, runner) in runners
            block = LLVM.BasicBlock(f, "site$id")
            LLVM.API.LLVMAddCase(sw, LLVM.ConstantInt(i64, id), block)
            LLVM.position!(builder, LLVM.at_end(block))
            nparams = length(LLVM.parameters(runner))
            args = nparams == 1 ? LLVM.Value[LLVM.parameters(f)[2]] : throw(ArgumentError("the finalizer of a site has $nparams parameters"))
            c = LLVM.call!(builder, LLVM.function_type(runner), runner, args)
            LLVM.callconv!(c, LLVM.callconv(runner))
            LLVM.br!(builder, done)
        end
        LLVM.position!(builder, LLVM.at_end(done))
        LLVM.ret!(builder)
    end
    return true
end
