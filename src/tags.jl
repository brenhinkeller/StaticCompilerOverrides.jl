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
# `runtime.jl`), but the allocations that GPUCompiler lowers (`julia.gc_alloc_obj`, which most objects of
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
function tag_allocations!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "julia.gc_alloc_obj") || return false
    changed = false
    for use in collect(LLVM.uses(fns["julia.gc_alloc_obj"]))
        call = LLVM.user(use)
        call isa LLVM.CallInst || continue
        typ = LLVM.operands(call)[3]
        known = typ isa LLVM.ConstantExpr && isinttoptr(typ) && constant_address(typ) !== nothing
        @dispose builder = LLVM.IRBuilder() begin
            obj = call
            # an object that can't refer to others is allocated as such (the lowering that would follow allocates them all alike)
            if known && Runtime.object_type(UInt(constant_address(typ))) === DataType &&
               Runtime.type_pointerfree(unsafe_pointer_to_objref(Ptr{Cvoid}(UInt(constant_address(typ)))))
                ftype = LLVM.FunctionType(LLVM.value_type(call), [LLVM.Int64Type()])
                atomic = get(LLVM.functions(mod), "gpu_gc_pool_alloc_atomic", nothing)
                atomic === nothing && (atomic = LLVM.Function(mod, "gpu_gc_pool_alloc_atomic", ftype))
                LLVM.position!(builder, LLVM.before(call))
                obj = LLVM.call!(builder, ftype, atomic, [LLVM.operands(call)[2]])
                LLVM.replace_uses!(call, obj)
                LLVM.erase!(call)
            end
            LLVM.position!(builder, LLVM.after(obj))
            tag = if known
                LLVM.ConstantInt(type_tag(UInt(constant_address(typ))))
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

# GPUCompiler lowers the intrinsics of Julia (allocation, ...) in `buildIntrinsicLoweringPipeline`, which
# is after the optimization of Julia (so only for the allocations that remain, not for those that are
# removed or put on the stack). The pass that tags is to be added before it. The passes of a pipeline are
# found by name, and have to be registered with the `PassBuilder` that runs it, which is made in
# `optimize!`: so for the jobs of ours (the code with the method table of this package: StaticCompiler also
# compiles code that doesn't have the runtime of this package), that is a copy of `optimize!` of
# GPUCompiler (see `optim.jl` there), that also registers ours.
#
# These are methods of functions of GPUCompiler, for the jobs of StaticCompiler: they are only used for our code.

# (the passes and pass builders of LLVM.jl have been renamed: `PassBuilder` is `NewPMPassBuilder`, ...)
const PassBuilder = isdefined(LLVM, :NewPMPassBuilder) ? LLVM.NewPMPassBuilder : LLVM.PassBuilder
const ModulePassManager = isdefined(LLVM, :NewPMModulePassManager) ? LLVM.NewPMModulePassManager : LLVM.ModulePassManager
const ModulePass = isdefined(LLVM, :NewPMModulePass) ? LLVM.NewPMModulePass : LLVM.ModulePass

const TagAllocationsPass = ModulePass("StaticTagAllocations", tag_allocations!)

is_ours(job) = GPUCompiler.method_table(job) === method_table

@static if isdefined(GPUCompiler, :buildIntrinsicLoweringPipeline) && isdefined(GPUCompiler, :optimize!)
    function GPUCompiler.buildIntrinsicLoweringPipeline(mpm, job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget}, opt_level)
        is_ours(job) && LLVM.add!(mpm, "StaticTagAllocations")
        return invoke(GPUCompiler.buildIntrinsicLoweringPipeline, Tuple{Any, GPUCompiler.CompilerJob, Any}, mpm, job, opt_level)
    end

    function GPUCompiler.optimize!(job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget}, mod::LLVM.Module,
                                   relocs::GPUCompiler.Relocations; opt_level = 2)
        is_ours(job) || return invoke(GPUCompiler.optimize!, Tuple{GPUCompiler.CompilerJob, LLVM.Module, GPUCompiler.Relocations},
                                      job, mod, relocs; opt_level)
        GPUCompiler.with_llvm_machine(job.config.target) do tm
            tti = GPUCompiler.llvm_targetinfo(job.config.target)
            @dispose pb = PassBuilder() begin
                tti === nothing || LLVM.target_transform_info!(pb, tti)

                # as in GPUCompiler
                LLVM.register!(pb, GPUCompiler.GPULowerCPUFeaturesPass(job))
                LLVM.register!(pb, GPUCompiler.GPULowerPTLSPass(job))
                LLVM.register!(pb, GPUCompiler.GPULowerGCFramePass(job, relocs))
                LLVM.register!(pb, GPUCompiler.GPULinkRuntimePass(job, relocs))
                LLVM.register!(pb, GPUCompiler.GPULinkLibrariesPass(job))
                LLVM.register!(pb, GPUCompiler.GPUFinishRuntimeIntrinsicsPass(job))
                LLVM.register!(pb, GPUCompiler.AddKernelStatePass(job))
                LLVM.register!(pb, GPUCompiler.LowerKernelStatePass(job))
                LLVM.register!(pb, GPUCompiler.CleanupKernelStatePass(job))
                # and ours
                LLVM.register!(pb, TagAllocationsPass)

                LLVM.add!(pb, ModulePassManager()) do mpm
                    GPUCompiler.buildNewPMPipeline!(mpm, job, opt_level)
                end
                LLVM.run!(pb, mod, tm)
            end
            GPUCompiler.optimize_module!(job, mod)
            LLVM.run!(LLVM.DeadArgumentEliminationPass(), mod, tm)
        end
        return
    end
end
