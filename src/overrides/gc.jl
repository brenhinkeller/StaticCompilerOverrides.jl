# The garbage collector, from the program: `GC.gc()` and `GC.enable`, and what the heap can tell about itself.
#
# The heap (`runtime/heap.jl`) is reached through `static_alloc(size, kind)`, which is what allocates; a negative size is a
# command (see `Heap.command`). These are the calls of a program that is compiled; none of them can be called in Julia.

heap_command(command::Int) = UInt(@symbolcall static_alloc(command::Int, 0::Int)::Ptr{UInt8})

# `GC.gc()` collects (when the program was compiled with `gc = true`: otherwise nothing is freed, and it does nothing)
@device_override Base.GC.gc(full::Bool = true) = (heap_command(Runtime.Heap.COLLECT); nothing)

# `GC.enable(false)` stops collections until `GC.enable(true)`; the answer is whether they were on
@device_override Base.GC.enable(on::Bool) = heap_command(on ? Runtime.Heap.ENABLE : Runtime.Heap.DISABLE) != 0

"""
    gc_live_bytes()

In a compiled program: the number of bytes of the heap that were in use after the last collection.
"""
gc_live_bytes() = Int(heap_command(Runtime.Heap.LIVE_BYTES))

"""
    gc_collections()

In a compiled program: the number of collections that there have been.
"""
gc_collections() = Int(heap_command(Runtime.Heap.COLLECTIONS))

"""
    gc_heap_bytes()

In a compiled program: the number of bytes that the heap has from the system (with the collector, what it uses is that and no
more, as long as the program doesn't keep growing what it uses).
"""
gc_heap_bytes() = Int(heap_command(Runtime.Heap.HEAP_BYTES))
