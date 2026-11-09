# `finalizer(f, x)` with a Julia function `f` (what the wrappers of C libraries have to free what the library allocated: PCRE, SuiteSparse, MPI, ...).
#
# The collector (`heap.jl`) is compiled apart and can't call code of the program, so a finalizer is run by the program: the call `finalizer(f, x)` is a *site*,
# of the types of `f` and `x` (each pair of types has a number, and a list of the objects that have a finalizer there, which keeps the function and, as a number, the
# address of the object: so it does not keep the object). The heap is told the object and the number of the site. When a collection finds the object unreachable the
# heap keeps it, and queues it, and after the collection hands it, with the number, to `static_run_finalizer(site, object)`: a function that is written when
# linking (`link_finalizers!` in `runtime.jl`), a `switch` on the number that calls `run_finalizer` of the site, which finds the function in the list, takes the
# entry out of it, and calls it with the object. Then nothing refers to the object, and a later collection frees it.
#
# How `link_finalizers!` finds the function of a site: `run_finalizer` has a call of `static_finalizer_marker(number)` in it (written in the code that is generated
# for it), and the call of `run_finalizer` that keeps it in the program is in a branch that is never taken (`FINALIZER_NEVER`).
#
# What is different from Julia: the finalizers run when the collector has finished a collection, at an allocation (as Julia's can), one after another, and not
# in the middle of another; an error that a finalizer throws is ignored (Julia prints it); the finalizers of objects that are alive when the program ends do not
# run (they do not in Julia, if the program exits with `exit()`, but they do when it ends normally).

const FINALIZER_SITES = Dict{Tuple{DataType,DataType},Int}()
const FINALIZER_REGISTRIES = Dict{Tuple{DataType,DataType},Any}()
const FINALIZER_NEVER = Ref(false)

@generated function finalizer_site_id(::Type{F}, ::Type{T}) where {F,T}
    id = get!(FINALIZER_SITES, (F, T)) do
        length(FINALIZER_SITES) + 1
    end
    return :($id)
end

# the list of the finalizers of the site: (address of the object, function), as a constant of the program (a list that the program changes)
@generated function finalizer_registry(::Type{F}, ::Type{T}) where {F,T}
    registry = get!(FINALIZER_REGISTRIES, (F, T)) do
        Tuple{UInt,F}[]
    end
    return :($registry)
end

@generated function finalizer_marker(::Val{ID}) where {ID}
    ir = "declare void @static_finalizer_marker(i64)\ndefine void @marker() alwaysinline {\n  call void @static_finalizer_marker(i64 $ID)\n  ret void\n}"
    return :(Base.llvmcall(($ir, "marker"), Cvoid, Tuple{}))
end

heap_command(command::Int, arg::Int) = UInt(@symbolcall static_alloc(command::Int, arg::Int)::Ptr{UInt8})

# run the finalizer that the site has for the object at `addr`
@noinline function run_finalizer(::Val{ID}, ::Type{F}, ::Type{T}, addr::UInt) where {ID,F,T}
    finalizer_marker(Val(ID))
    registry = finalizer_registry(F, T)
    i = 1
    while i <= length(registry)
        if registry[i][1] == addr
            f = registry[i][2]
            registry[i] = registry[end]
            pop!(registry)
            o = unsafe_pointer_to_objref(Ptr{Cvoid}(addr))::T
            try
                f(o)
            catch
            end
            return nothing
        end
        i += 1
    end
    return nothing
end

@noinline function finalizer_site(f::F, o::T) where {F,T}
    id = finalizer_site_id(F, T)
    addr = UInt(pointer_from_objref(o))
    push!(finalizer_registry(F, T), (addr, f))
    heap_command(Runtime.Heap.FINALIZER_SITE, id)
    heap_command(Runtime.Heap.FINALIZER_OBJECT, Int(addr))
    FINALIZER_NEVER[] && run_finalizer(Val(id), F, T, UInt(0)) # (not taken: it keeps `run_finalizer` for this site in the program)
    return nothing
end

# (a function that is a pointer to a C function is `ijl_gc_add_ptr_finalizer`, in the runtime)
@device_override function Base.finalizer(f::Function, o::T) where {T}
    Base.ismutabletype(T) || error("objects of type ", T, " cannot be finalized")
    finalizer_site(f, o)
    return o
end
