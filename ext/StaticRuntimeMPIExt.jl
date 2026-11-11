# MPI.jl in a compiled program. MPI is a library that the program calls (see `runtime/libraries.jl`: MPI.jl opens `libmpi` with `RTLD_GLOBAL` when it is loaded, and
# calls its functions by name; the program opens it, from the path that it has when compiling, when it first calls one), and what is different is what MPI.jl does when
# it starts up and ends:
#
# * `MPI.Init` runs the functions that were registered with `MPI.add_init_hook!` (the types of MPI.jl set up their handles), a list of functions of different
#   types that it calls one after another. They are the ones that are registered when compiling: here they are called by name, in the same order (and the finalize hooks
#   in the opposite order, as MPI.jl does).
# * `MPI.Init` registers a function with `atexit` that calls `MPI.Finalize` when the program ends, which a compiled program does not run: call `MPI.Finalize()`
#   yourself at the end (`finalize_atexit` is ignored).
#
#
# The handles of the constants (`MPI.COMM_WORLD`, `MPI.INT`, `MPI.SUM`, ...) are the numbers that the library has them as when compiling, which are
# the same each time for the MPICH family (MPICH, Intel MPI, and the libraries of the MPI ABI), and are addresses for Open MPI, which a program that is compiled can't use.
module StaticRuntimeMPIExt

using StaticRuntime: @device_override
using MPI: MPI

# the hooks that are registered now, written as calls of each (the functions are constants, so each call is to a function whose type is known)
@generated function call_hooks(::Val{which}) where {which}
    hooks = which === :init ? copy(MPI.mpi_init_hooks) : reverse(copy(MPI.mpi_finalize_hooks))
    return Expr(:block, (Expr(:call, QuoteNode(h)) for h in hooks)..., nothing)
end

const INIT_DONE = Ref(false)
const FINALIZE_DONE = Ref(false)

@device_override function MPI.run_init_hooks()
    INIT_DONE[] && return nothing
    INIT_DONE[] = true
    call_hooks(Val(:init))
    return nothing
end

@device_override function MPI.run_finalize_hooks()
    FINALIZE_DONE[] && return nothing
    FINALIZE_DONE[] = true
    call_hooks(Val(:finalize))
    return nothing
end

# `MPI.Init` of MPI.jl, without the function for `atexit`
@device_override function MPI.Init(; threadlevel = :serialized, finalize_atexit = true, errors_return = true)
    if threadlevel isa Symbol
        threadlevel = MPI.ThreadLevel(threadlevel)
    end
    if MPI.Finalized()
        error("MPI cannot be initialized after MPI.Finalize has been called.")
    end
    if MPI.Initialized()
        provided = MPI.Query_thread()
        if provided < threadlevel
            @warn "MPI already initialized with thread level $provided, requested = $threadlevel"
        end
    else
        provided = MPI._init_thread(threadlevel)
        if provided < threadlevel
            @warn "MPI thread level requested = $threadlevel, provided = $provided"
        end
        MPI.run_init_hooks()
        if errors_return
            MPI.set_default_error_handler_return()
        end
    end
    return provided
end

end
