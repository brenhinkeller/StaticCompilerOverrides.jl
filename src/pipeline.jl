# The LLVM pipeline of our compilations: what GPUCompiler runs, with what we change in it (the jobs whose parameters are `OverridesParams`; StaticCompiler's own are not changed).
#
# * The vectorizers run, as they do for Julia (but not the SLP vectorizer, which crashes).
# * The allocations are given their type tag before they are lowered (see `tags.jl`), and the constants that are types are put where they are looked for (the numbers of the types
#   of the binary).
#
# (These are methods of functions of GPUCompiler that a version of it may not have: then this package does not load, which is better than a pipeline without the tags.)

using GPUCompiler: GPUCompiler
using LLVM: LLVM, @dispose

# GPUCompiler runs the loop and SLP vectorizers only for the jobs that say they can (`can_vectorize`, false by default: it is true for its native and GPU
# targets, and not for StaticCompiler's). Without them a loop with `@simd` is not vectorized, nor its reduction reordered, so the result of `sum`, `dot` and
# the like is that of a plain loop: different in the last digits from what Julia gives (which uses the vectorizer) and less accurate. Our jobs
# (the type of the parameters is ours) run them, as Julia does.
GPUCompiler.can_vectorize(::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget, OverridesParams}) = true

# The passes of the vectorizers of GPUCompiler (`buildVectorPipeline`) without the SLP vectorizer: that of the LLVM of Julia 1.14 crashes the process (a null
# pointer in `BoUpSLP::getTreeCost`) on some of the code that is compiled, which showed with `--check-bounds=yes` (what CI uses) and the code of `show` for arrays. The loop
# vectorizer is what makes the reductions of `@simd` loops those of Julia (the SLP vectorizer makes none of them), and is kept.
function GPUCompiler.buildVectorPipeline(fpm, job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget, OverridesParams}, opt_level)
    LLVM.add!(fpm, LLVM.LoopPassManager()) do lpm
        LLVM.add!(lpm, LLVM.LoopRotatePass())
        LLVM.add!(lpm, LLVM.LoopDeletionPass())
    end
    LLVM.add!(fpm, LLVM.LoopDistributePass())
    LLVM.add!(fpm, LLVM.InjectTLIMappings())
    LLVM.add!(fpm, LLVM.LoopVectorizePass())
    LLVM.add!(fpm, LLVM.LoopLoadEliminationPass())
    LLVM.add!(fpm, GPUCompiler.simplifycfg_pass(job, GPUCompiler.AggressiveSimplifyCFGOptions))
    LLVM.add!(fpm, LLVM.LoopPassManager(; use_memory_ssa = true)) do lpm
        LLVM.add!(lpm, LLVM.LICMPass())
    end
    LLVM.add!(fpm, LLVM.EarlyCSEPass())
    LLVM.add!(fpm, LLVM.CorrelatedValuePropagationPass())
    LLVM.add!(fpm, GPUCompiler.instcombine_pass(job))
    LLVM.add!(fpm, LLVM.VectorCombinePass())
    LLVM.add!(fpm, LLVM.LoopUnrollPass(; opt_level))
    LLVM.add!(fpm, LLVM.SROAPass(; preserve_cfg = true))
    LLVM.add!(fpm, LLVM.InstSimplifyPass())
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

is_ours(job) = GPUCompiler.method_table(job) === method_table

function GPUCompiler.buildIntrinsicLoweringPipeline(mpm, job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget, OverridesParams}, opt_level)
    is_ours(job) && LLVM.add!(mpm, "StaticTagAllocations")
    return invoke(GPUCompiler.buildIntrinsicLoweringPipeline, Tuple{Any, GPUCompiler.CompilerJob, Any}, mpm, job, opt_level)
end

function GPUCompiler.optimize!(job::GPUCompiler.CompilerJob{<:StaticCompiler.StaticCompilerTarget, OverridesParams}, mod::LLVM.Module,
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
            LLVM.register!(pb, TypeConstantsPass)

            LLVM.add!(pb, ModulePassManager()) do mpm
                LLVM.add!(mpm, "StaticTypeConstants") # (before anything is optimized)
                GPUCompiler.buildNewPMPipeline!(mpm, job, opt_level)
            end
            LLVM.run!(pb, mod, tm)
        end
        GPUCompiler.optimize_module!(job, mod)
        LLVM.run!(LLVM.DeadArgumentEliminationPass(), mod, tm)
    end
    return
end
