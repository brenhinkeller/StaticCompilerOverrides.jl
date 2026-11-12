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

# Whether the collector has no reason to look at an object of the type `T` as part of the data of the program: it can't refer to an object of the heap, as it is not changed to (strings, symbols and plain
# data are not, and the objects that are types are never made when the program runs; a `const` array or struct of references can be, and is looked at). Also not looked at: what only refers to such objects.
function root_free(T)
    type_pointerfree(T) && return true
    return T === String || T === Symbol || T === DataType || T === Core.TypeName || T === Core.SimpleVector || T === Union || T === UnionAll || T === Core.TypeVar
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
const HEAP_IR = Dict{Tuple{Bool,Bool},String}()

# The functions of the heap that run and register finalizers (`julia_` and then the name, and a number): a program that has no finalizers has them do nothing, so that they and what only they call
# (several kilobytes) are not in it.
const FINALIZER_FUNCTIONS = ("julia_run_finalizers_", "julia_run_pending_finalizers_", "julia_add_finalizer_")

function heap_ir(gc::Bool, finalizers::Bool = true)
    key = (gc, gc && finalizers)
    haskey(HEAP_IR, key) && return HEAP_IR[key]
    alloc = gc ? Heap.alloc : Heap.alloc_nogc
    heap = StaticCompiler.compile_llvm_module(alloc, (Int, Int), "static_alloc")
    try
        if gc && !finalizers
            for fn in collect(LLVM.functions(heap))
                (LLVM.isdeclaration(fn) || !any(prefix -> startswith(LLVM.name(fn), prefix), FINALIZER_FUNCTIONS)) && continue
                # (a function with nothing in it, instead of this one)
                name = LLVM.name(fn)
                empty = LLVM.Function(heap, name * ".empty", LLVM.function_type(fn))
                LLVM.@dispose builder = LLVM.IRBuilder() begin
                    LLVM.position!(builder, LLVM.at_end(LLVM.BasicBlock(empty, "entry")))
                    LLVM.ret!(builder)
                end
                LLVM.replace_uses!(fn, empty)
                LLVM.erase!(fn)
                LLVM.name!(empty, name)
            end
        end
        for fn in LLVM.functions(heap)
            LLVM.isdeclaration(fn) || LLVM.name(fn) == "static_alloc" || LLVM.linkage!(fn, LLVM.API.LLVMInternalLinkage)
        end
        for g in LLVM.globals(heap)
            LLVM.isdeclaration(g) || LLVM.linkage!(g, LLVM.API.LLVMInternalLinkage)
        end
        run!(GlobalDCEPass(), heap)
        HEAP_IR[key] = string(heap)
    finally
        LLVM.dispose(heap)
    end
    return HEAP_IR[key]
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
        haskey(LLVM.metadata(g), "static.pointerfree") && continue # (see `embed_new_global!`)
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
function link_heap!(mod::LLVM.Module; gc = false, finalizers = true)
    fns = LLVM.functions(mod)
    haskey(fns, "static_alloc") && LLVM.isdeclaration(fns["static_alloc"]) || return false
    collect_garbage = gc !== false
    if collect_garbage
        Sys.isapple() || Sys.islinux() || throw(ArgumentError("the garbage collector is not available on this system (use `gc = false`)"))
        run!(GlobalDCEPass(), mod) # (the roots refer to the objects, which would keep those that the code does not use)
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
    heap = parse(LLVM.Module, heap_ir(collect_garbage, finalizers))
    LLVM.datalayout!(heap, LLVM.datalayout(mod))
    LLVM.triple!(heap, LLVM.triple(mod))
    LLVM.link!(mod, heap) # consumes `heap`
    return true
end

# Whether a program that has a collector would never use it: whether it never frees anything that it needs to.
#
# Always: when nothing that is thrown is caught (a `try` that only runs what is to be done after, and throws on, as `finally` does: the part of it that runs for an exception ends in
# `unreachable`), and everything that the program allocates is allocated where it can only go on to throw (the message and the exception of an error: such a block ends in
# `unreachable`, and the program stops; a loop that builds the message is fine, if it is in the part that only stops, and not where the function starts). What is allocated is then a few objects, and the allocator
# that does not collect is enough. What makes the arguments of the command line is not counted (`ignored`, below).
#
# With `bounded` (the program is one that runs once, as an executable does): when everything that it allocates is allocated a finite number of times. An allocation is not repeated if it is not
# in a loop of its function, and the function is called, where it is, only from places that are not repeated either (not in a loop, in a function that is not repeated, and not in a function that calls
# itself, directly or by others). A function that something refers to without calling it (a callback of a library) can be called any number of times. The memory that the program has
# is then what it allocates in all, which is some number of objects, and not what it allocates for as long as it runs. (A catch that goes on is fine, if what it is in is not repeated.)
function allocation_is_finite(mod::LLVM.Module; bounded::Bool = false)
    allocators = Set([INLINED_ALLOCATORS..., "static_alloc"])
    # whether the program is about to stop where the block is: whether every way on from it ends in `unreachable` (an error that is thrown, or an abort), and none of it goes on to a `ret` or to anything that is not
    # known. A loop on the way is fine if it is in the part of the program that only stops: what builds the message of an error (`show`, `escape_string`, `join`) is a loop, and runs once, for an
    # error. It is not if that part is where the program starts: a loop that goes on until it throws, or exits, is the program, and what it allocates is allocated each time round.
    abort_only_cache = Dict{Ptr{Cvoid},Bool}() # (whether no way on from the block goes on, and one ends in `unreachable`: loops do not matter)
    function abort_only(bb::LLVM.BasicBlock)
        get!(abort_only_cache, Ptr{Cvoid}(bb.ref)) do
            seen = Set{Ptr{Cvoid}}()
            todo = [bb]
            aborts = false
            while !isempty(todo)
                b = pop!(todo)
                key = Ptr{Cvoid}(b.ref)
                key in seen && continue
                push!(seen, key)
                term = LLVM.terminator(b)
                if term isa LLVM.UnreachableInst
                    aborts = true
                elseif term isa LLVM.BrInst || term isa LLVM.SwitchInst
                    append!(todo, LLVM.successors(term))
                else
                    return false # (`ret`, and what is not known)
                end
            end
            aborts
        end
    end
    # whether a way on from the block goes round (in the blocks that can be reached from it)
    function goes_round(bb::LLVM.BasicBlock)
        state = Dict{Ptr{Cvoid},Int}() # (1: on the way from `bb`, 2: done)
        function visit(b)
            key = Ptr{Cvoid}(b.ref)
            get(state, key, 0) == 1 && return true
            get(state, key, 0) == 2 && return false
            state[key] = 1
            term = LLVM.terminator(b)
            found = (term isa LLVM.BrInst || term isa LLVM.SwitchInst) && any(visit, LLVM.successors(term))
            state[key] = 2
            return found
        end
        return visit(bb)
    end
    predecessors_cache = Dict{Ptr{Cvoid},Dict{Ptr{Cvoid},Vector{LLVM.BasicBlock}}}() # (of the blocks of each function)
    function predecessors(fn::LLVM.Function)
        get!(predecessors_cache, Ptr{Cvoid}(fn.ref)) do
            preds = Dict{Ptr{Cvoid},Vector{LLVM.BasicBlock}}()
            for b in LLVM.blocks(fn)
                term = LLVM.terminator(b)
                (term isa LLVM.BrInst || term isa LLVM.SwitchInst) || continue
                for succ in LLVM.successors(term)
                    push!(get!(Vector{LLVM.BasicBlock}, preds, Ptr{Cvoid}(succ.ref)), b)
                end
            end
            preds
        end
    end
    # whether the way from the start of the function to the block is through blocks that only stop: whether the function begins with the part that it is about to stop in
    function starts_stopping(bb::LLVM.BasicBlock)
        fn = LLVM.parent(bb)
        entry = first(LLVM.blocks(fn))
        preds = predecessors(fn)
        seen = Set{Ptr{Cvoid}}()
        todo = [bb]
        while !isempty(todo)
            b = pop!(todo)
            b == entry && return true
            key = Ptr{Cvoid}(b.ref)
            key in seen && continue
            push!(seen, key)
            for p in get(preds, key, LLVM.BasicBlock[])
                abort_only(p) && push!(todo, p) # (a block that can go on is a place that this part is entered from)
            end
        end
        return false
    end
    dies(bb::LLVM.BasicBlock) = abort_only(bb) && (!goes_round(bb) || !starts_stopping(bb))
    # whether the block is in a loop of its function: whether it can be reached from itself (what is not known is taken to be)
    function in_loop(bb::LLVM.BasicBlock)
        seen = Set{Ptr{Cvoid}}()
        todo = LLVM.BasicBlock[]
        function push_successors(b)
            term = LLVM.terminator(b)
            term isa LLVM.UnreachableInst && (append!(todo, get(catches, Ptr{Cvoid}(LLVM.parent(b).ref), LLVM.BasicBlock[])); return true) # (a throw goes to a catch of the function, if there is one)
            term isa LLVM.RetInst && return true
            (term isa LLVM.BrInst || term isa LLVM.SwitchInst) || return false
            append!(todo, LLVM.successors(term))
            return true
        end
        push_successors(bb) || return true
        while !isempty(todo)
            b = pop!(todo)
            b == bb && return true
            key = Ptr{Cvoid}(b.ref)
            key in seen && continue
            push!(seen, key)
            push_successors(b) || return true
        end
        return false
    end
    # Whether an exception that is thrown stops the program: whether what a `catch` runs for an exception ends in `unreachable`. (If it does not, a block that ends in `unreachable` can be followed by
    # more of the program, and is no end.) A `try` is `sigsetjmp` and a branch on whether it is 0 (nothing was thrown): the other branch is what catches.
    stops_at_throw = true
    try_sites = Tuple{LLVM.Function,LLVM.BasicBlock}[]
    catches = Dict{Ptr{Cvoid},Vector{LLVM.BasicBlock}}() # (the blocks that catch, of each function: after a throw, control goes to one of them)
    for fn in LLVM.functions(mod)
        LLVM.isdeclaration(fn) && continue
        for bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
            inst isa LLVM.CallInst || continue
            callee = LLVM.called_operand(inst)
            callee isa LLVM.Function && occursin("setjmp", LLVM.name(callee)) || continue
            push!(try_sites, (fn, bb))
            for use in LLVM.uses(inst)
                compare = LLVM.user(use)
                if !(compare isa LLVM.ICmpInst && LLVM.predicate(compare) == LLVM.API.LLVMIntEQ)
                    @debug("setjmp used as not expected", function_name = LLVM.name(fn))
                    stops_at_throw = false
                    continue
                end
                for branch_use in LLVM.uses(compare)
                    branch = LLVM.user(branch_use)
                    if !(branch isa LLVM.BrInst && length(LLVM.successors(branch)) == 2)
                        @debug("setjmp branch not expected", function_name = LLVM.name(fn))
                        stops_at_throw = false
                    elseif (push!(get!(Vector{LLVM.BasicBlock}, catches, Ptr{Cvoid}(fn.ref)), last(collect(LLVM.successors(branch)))); !dies(last(collect(LLVM.successors(branch))))) # (the false branch: it was thrown)
                        @debug("a catch that goes on", function_name = LLVM.name(fn))
                        stops_at_throw = false
                    end
                end
            end
        end
    end
    stops_at_throw || bounded || return false
    defined = [fn for fn in LLVM.functions(mod) if !LLVM.isdeclaration(fn) && !(LLVM.name(fn) in allocators)]
    calls = Dict{Ptr{Cvoid},Vector{Tuple{LLVM.Function,LLVM.BasicBlock}}}() # (where each is called from)
    called_only = Set{Ptr{Cvoid}}()  # (those that are only called: nothing refers to them otherwise)
    roots = Set{Ptr{Cvoid}}()        # (those that nothing refers to: the entry point)
    # A call of a function of the runtime by `ccall` goes through a function of its own (`jlplt_name`), which refers to the function, and calls it by its address: it is a call of the function
    in_stub(inst) = LLVM.name(LLVM.parent(LLVM.parent(inst))) |> name -> startswith(name, "jlplt_")
    stub_got(user) = user isa LLVM.GlobalVariable && startswith(LLVM.name(user), "jlplt_") && endswith(LLVM.name(user), "_got") # (the table of the addresses of the stubs)
    stubs = Tuple{LLVM.Function,LLVM.Function}[] # (a stub, the function that it calls)
    for fn in defined
        startswith(LLVM.name(fn), "jlplt_") || continue
        for bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
            inst isa LLVM.StoreInst || continue
            target = LLVM.operands(inst)[1]
            target isa LLVM.Function && target != fn && !startswith(LLVM.name(target), "jlplt_") && (push!(stubs, (fn, target)); break)
        end
    end
    for fn in defined
        sites = Tuple{LLVM.Function,LLVM.BasicBlock}[]
        only_calls = true
        used = false
        for use in LLVM.uses(fn)
            used = true
            inst = LLVM.user(use)
            if inst isa LLVM.CallInst && LLVM.called_operand(inst) == fn
                push!(sites, (LLVM.parent(LLVM.parent(inst)), LLVM.parent(inst)))
            elseif stub_got(inst) || (inst isa LLVM.Instruction && in_stub(inst))
                continue
            else
                only_calls = false
            end
        end
        key = Ptr{Cvoid}(fn.ref)
        calls[key] = sites
        used || push!(roots, key)
        used && only_calls && push!(called_only, key)
    end
    for (stub, target) in stubs # (what calls the stub calls the function)
        haskey(calls, Ptr{Cvoid}(target.ref)) && haskey(calls, Ptr{Cvoid}(stub.ref)) && append!(calls[Ptr{Cvoid}(target.ref)], calls[Ptr{Cvoid}(stub.ref)])
    end
    # What makes the arguments of the command line (`command_line_arguments`, `set_base_args`) allocates as much as there are arguments, which the system limits and the program does not
    # decide: it is not counted, in any function that they call (that is only called from them, or where the program is about to stop) either
    ignored(fn) = startswith(LLVM.name(fn), "julia_command_line_arguments") || startswith(LLVM.name(fn), "julia_set_base_args")
    stops = Dict{Ptr{Cvoid},Bool}() # (the blocks that only lead to `unreachable`)
    dying_is_final = Ref(stops_at_throw) # (whether what is after a throw is no more of the program)
    block_dies(b) = dying_is_final[] && get!(() -> dies(b), stops, Ptr{Cvoid}(b.ref))
    loops = Dict{Ptr{Cvoid},Bool}()
    # (the loop that makes the arguments of the command line is one that runs as many times as there are arguments, which is fixed when the program starts: see `command_line_arguments`)
    block_in_loop(b) = get!(loops, Ptr{Cvoid}(b.ref)) do
        startswith(LLVM.name(LLVM.parent(b)), "julia_command_line_arguments") ? false : in_loop(b)
    end
    # The functions that run a finite number of times, from the entry point on (what is called from itself is not reached)
    function run_once()
        once = copy(roots)
        while true
            added = false
            for fn in defined
                key = Ptr{Cvoid}(fn.ref)
                (key in once || !(key in called_only)) && continue
                if all(site -> block_dies(site[2]) || (Ptr{Cvoid}(site[1].ref) in once && !block_in_loop(site[2])), calls[key])
                    push!(once, key)
                    added = true
                end
            end
            added || return once
        end
    end
    once = Set{Ptr{Cvoid}}()
    if bounded
        if !stops_at_throw
            # A catch that goes on: what is thrown is not the end, but each throw is for a `try` that was run, so the throws are as many as the `try`s are run, which is finite if none is in a loop
            # or in a function that is run again and again
            once = run_once()
            dying_is_final[] = all(site -> Ptr{Cvoid}(site[1].ref) in once && !block_in_loop(site[2]), try_sites)
        end
        once = run_once()
    end
    # The functions that are only called where the program is about to stop (the function that makes an exception, which its caller throws): what they allocate is allocated then too.
    doomed = copy(called_only)
    changed = true
    while changed
        changed = false
        for fn in defined
            key = Ptr{Cvoid}(fn.ref)
            key in doomed || continue
            if !all(site -> block_dies(site[2]) || ignored(site[1]) || Ptr{Cvoid}(site[1].ref) in doomed, calls[key])
                delete!(doomed, key)
                changed = true
            end
        end
    end
    for fn in defined
        key = Ptr{Cvoid}(fn.ref)
        (key in doomed || ignored(fn)) && continue
        for bb in LLVM.blocks(fn)
            allocating = false
            for inst in LLVM.instructions(bb)
                inst isa LLVM.CallInst || continue
                callee = LLVM.called_operand(inst)
                callee isa LLVM.Function && LLVM.name(callee) in allocators && (allocating = true; break)
            end
            allocating || continue
            block_dies(bb) && continue
            bounded && key in once && !block_in_loop(bb) && continue
            @debug("A collector is needed: this function allocates where it can return" * (bounded ? ", or repeatedly" : ""), function_name = LLVM.name(fn),
                   called_from = join([string(LLVM.name(site[1]), " once=", Ptr{Cvoid}(site[1].ref) in once, " dies=", block_dies(site[2]), " loop=", block_in_loop(site[2])) for site in calls[key]], "; "), in_once = key in once, called_only = key in called_only)
            return false
        end
    end
    return true
end

# Whether the code registers finalizers: a C function for an object (`BigInt` does), or `finalizer(f, x)`, which is marked for `link_finalizers!`
function uses_finalizers(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    return any(name -> haskey(fns, name), ("ijl_gc_add_ptr_finalizer", "jl_gc_add_ptr_finalizer", "static_finalizer_marker"))
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
