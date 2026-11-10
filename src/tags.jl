# Type tags.
#
# Every object in Julia has a *type tag*, the word before it, which is what `typeof`, `isa`, and
# dynamic dispatch look at: for a type that is one of the few builtin ones (`Int64`, `String`, `Symbol`, ...)
# it is a small number, which is the position of the type in `jl_small_typeof`, and for any other type it is
# the address of the type object. Compiled code that checks the type of an object compares the tag with
# these (as numbers: for the code that we compile, those of the Julia that compiled it).
#
# So the objects that the program makes need the tag, which is written by whoever makes the object. For
# most that is the code that Julia generated (`julia.gc_alloc_bytes`, and the runtime functions of
# `runtime/shims.jl`), but the allocations that GPUCompiler lowers (`julia.gc_alloc_obj`, which most objects of
# user types are) lose the type, since only the size is needed for allocating. A pass before that lowering
# writes the tag.

using LLVM: LLVM, @dispose
using StaticCompiler: StaticCompiler, isinttoptr, constant_address
using GPUCompiler: GPUCompiler

# the tag of the objects of the type at address `addr`: the position of the type in `jl_small_typeof`
# (times 8), if it is in there, and its address otherwise
function type_tag(addr::UInt)
    table = cglobal(:jl_small_typeof, Ptr{Ptr{Cvoid}})
    for i in 0:127
        unsafe_load(table, i + 1) == Ptr{Cvoid}(addr) && return Int64(i << 3)
    end
    return Int64(addr)
end

# Write the type tag of each of the objects that the allocation intrinsic `julia.gc_alloc_obj(ptls, size, type)`
# makes, in the 8 bytes before the object (which is where the tag goes: the runtime allocates a header
# for them)
# The global that stands for the type at `addr` while the code is optimized (see below, and `resolve_type_placeholders!`)
function type_placeholder(mod::LLVM.Module, addr::UInt)
    name = string(Runtime.TYPE_PLACEHOLDER, string(addr, base = 16))
    g = get(LLVM.globals(mod), name, nothing)
    if g === nothing
        g = LLVM.GlobalVariable(mod, LLVM.Int8Type(), name)
        LLVM.linkage!(g, LLVM.API.LLVMExternalLinkage)
        LLVM.visibility!(g, LLVM.API.LLVMHiddenVisibility)
    end
    return g
end

function tag_allocations!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "julia.gc_alloc_obj") || return false
    changed = false
    for use in collect(LLVM.uses(fns["julia.gc_alloc_obj"]))
        call = LLVM.user(use)
        call isa LLVM.CallInst || continue
        typ = LLVM.operands(call)[3]
        addr = Runtime.constant_object_address(typ) # (a type, as a constant)
        known = addr !== nothing
        @dispose builder = LLVM.IRBuilder() begin
            obj = call
            # an object that can't refer to others is allocated as such (the lowering that would follow allocates them all alike)
            if known && Runtime.object_type(addr) === DataType &&
               Runtime.type_pointerfree(unsafe_pointer_to_objref(Ptr{Cvoid}(addr)))
                ftype = LLVM.FunctionType(LLVM.value_type(call), [LLVM.Int64Type()])
                atomic = Runtime.declare!(mod, "gpu_gc_pool_alloc_atomic", ftype)
                LLVM.position!(builder, LLVM.before(call))
                obj = LLVM.call!(builder, ftype, atomic, [LLVM.operands(call)[2]])
                LLVM.replace_uses!(call, obj)
                LLVM.erase!(call)
            end
            LLVM.position!(builder, LLVM.after(obj))
            tag = if known
                t = type_tag(addr)
                # (a builtin type has a small number as its tag; the others the address of the type, which is the type in the binary)
                t == Int64(addr) ? LLVM.const_ptrtoint(type_placeholder(mod, addr), LLVM.Int64Type()) : LLVM.ConstantInt(t)
            else
                LLVM.ptrtoint!(builder, typ, LLVM.Int64Type()) # a type that is only known when running
            end
            slot = LLVM.gep!(builder, LLVM.Int8Type(), obj, [LLVM.ConstantInt(Int64(-8))])
            LLVM.store!(builder, tag, slot)
        end
        changed = true
    end
    return changed
end

# (the passes and pass builders of LLVM.jl have been renamed: `PassBuilder` is `NewPMPassBuilder`, ...)
const PassBuilder = isdefined(LLVM, :NewPMPassBuilder) ? LLVM.NewPMPassBuilder : LLVM.PassBuilder
const ModulePassManager = isdefined(LLVM, :NewPMModulePassManager) ? LLVM.NewPMModulePassManager : LLVM.ModulePassManager
const ModulePass = isdefined(LLVM, :NewPMModulePass) ? LLVM.NewPMModulePass : LLVM.ModulePass

const TagAllocationsPass = ModulePass("StaticTagAllocations", tag_allocations!)

# The addresses of type objects that the code that Julia generates compares the tags of objects with (`isa`, `typeof`), and passes on, as numbers, are those
# of this process, which are not those in the binary (where the types are objects that are copied into it: see `embed_constants!`). They
# are replaced after the code is optimized. But LLVM does arithmetic with such numbers while it optimizes: a chain of tests of a tag
# against types becomes a `switch` on `(tag + C)` rotated, where `C` and the numbers of the cases are those of the *addresses of
# this process*, and what the arithmetic gives for the tags of the binary is another thing. So the addresses are not numbers when it
# is optimized: before that, each is a global that is declared (`static_type_<address>`), whose address LLVM can't know, and `embed_constants!`
# makes them the objects.
function placeholder_type_constants!(mod::LLVM.Module)
    i64 = LLVM.Int64Type()
    placeholder(addr::UInt) = type_placeholder(mod, addr)
    changed = false
    # the tags that are compared, stored and passed on as numbers
    for (addr, uses) in Runtime.type_number_constants(mod)
        number = LLVM.const_ptrtoint(placeholder(addr), i64)
        for (inst, i) in uses
            LLVM.operands(inst)[i] = number
        end
        changed = true
    end
    # the types that are pointers, in the code and in the initializers of the globals that it loads them from (which LLVM folds into
    # the code: a type is a `private constant` global that holds its address)
    nodes = Dict{UInt,Vector{LLVM.Value}}()
    for (addr, ops) in Runtime.inttoptr_constants(mod)
        append!(get!(Vector{LLVM.Value}, nodes, addr), ops)
    end
    for g in LLVM.globals(mod)
        LLVM.isdeclaration(g) && continue
        init = LLVM.initializer(g)
        init === nothing && continue
        for node in Runtime.inttoptr_nodes(init)
            addr = constant_address(node)
            addr === nothing && continue
            push!(get!(Vector{LLVM.Value}, nodes, UInt(addr)), node)
        end
    end
    for (addr, ops) in nodes
        Runtime.object_type(addr) === DataType || continue
        ph = placeholder(addr)
        for op in ops
            LLVM.replace_uses!(op, ph)
        end
        changed = true
    end
    return changed
end

const TypeConstantsPass = ModulePass("StaticTypeConstants", placeholder_type_constants!)
