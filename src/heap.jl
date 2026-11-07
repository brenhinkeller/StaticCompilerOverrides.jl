# The heap of compiled programs: where everything that Julia allocates comes from, and the garbage collector that
# frees what is not used any more.
#
# This is written in Julia, over raw pointers, and compiled with StaticCompiler like any other code (once for the
# session, and the code is cached: see `link_heap!` in `runtime.jl`). It must not allocate, throw or dispatch
# dynamically: that is what the pipeline itself checks. Its state is in a global of its own (an LLVM global, and not a
# Julia object, which would be an address in this process: it has to be in the module as it is).
#
# Objects have a header of 16 bytes before them (the type tag, written by the code that allocates, and padding that
# makes the object 16-byte aligned), and are all zero when allocated.
#
# There are two allocators. `alloc_nogc` hands out memory from chunks and never frees it. `alloc` is a *conservative,
# non-moving, mark and sweep* garbage collector, which is safe for all code that Julia can generate:
#
# * What can refer to an object is looked for without knowing the types: every word of the stack (and the registers),
#   of the data of the program that can refer to heap objects, and of the objects that are reached, that is the address
#   of an object, or of anything inside it (or just after it, which is what a loop that has gone past the end of an array
#   holds), keeps it. A number that looks like an address keeps an object that is not used: it can't make anything
#   unsafe. Objects don't move, so the addresses that the code holds are still right.
# * What is known is the kind of allocation: whether the object can hold references (see `ATOMIC`), which is decided when
#   compiling, from the type. Objects that can't (strings, arrays of numbers, boxed numbers) are not looked inside.
# * Small objects are in blocks of one size class, each with a bitmap of the cells that are in use and one of those that
#   were reached; large objects have memory of their own.

module Heap

using StaticTools: calloc, free, @symbolcall, @c_str

const NORMAL, ATOMIC = 0, 1 # the kinds of allocation: the object may have references, or it has none

## the memory of the heap

# the commands that the program can give the heap (see `command`)
const COLLECT, LIVE_BYTES, COLLECTIONS, HEAP_BYTES, DISABLE, ENABLE = -1, -2, -3, -4, -5, -6

const CHUNK_SIZE = 1 << 20 # for `alloc_nogc`
const LARGE_SIZE = CHUNK_SIZE >> 2

const BLOCK_SIZE = UInt(1 << 16) # of the blocks of the small objects, which are got in chunks of 16
const CHUNK_BLOCKS = 16
const HEADER = UInt(640) # at the start of a block (and what is in it: see `B_`), before the cells
const LARGE_HEADER = UInt(64) # of a large object, before it
const MAX_SMALL = UInt(2048) # the largest cell: objects that don't fit are large
const NCLASSES = 23
const MIN_THRESHOLD = UInt(8) << 20 # bytes allocated between collections, at least; and as much as is alive after one
const BITMAP_WORDS = 32 # (of 64 cells: 2048 cells are the most that a block has)

# the words of a block header, and of a large object's
const B_TYPE, B_CELL, B_NCELLS, B_KIND, B_CLASS, B_NEXT, B_CURSOR, B_CLEAN, B_ALLNEXT, B_POOLED = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9
const B_ALLOC, B_MARK = 10, 10 + BITMAP_WORDS # the bitmaps: the cells in use, and the cells reached
const L_TYPE, L_SIZE, L_MARK, L_KIND, L_ALLNEXT = 0, 1, 2, 3, 4
const TYPE_BLOCK, TYPE_LARGE = UInt(1), UInt(2)

## the state: words of a global

const S_STACK_BASE, S_NOGC_CUR, S_NOGC_STOP, S_BYTES, S_CHUNKS = 1, 2, 3, 4, 5
const S_INIT, S_CHUNK_CUR, S_CHUNK_END, S_POOL, S_BLOCKS, S_LARGE = 6, 7, 8, 9, 10, 11
const S_EXT, S_EXT_N, S_EXT_CAP, S_LO, S_HI = 12, 13, 14, 15, 16
const S_STACK, S_STACK_N, S_STACK_CAP = 17, 18, 19 # the mark stack
const S_SINCE, S_THRESHOLD, S_LIVE, S_COLLECTIONS, S_COLLECTING = 20, 21, 22, 23, 24
const S_XROOTS, S_XROOTS_N, S_STRESS, S_STRESS_LEFT, S_SCAN_STACK = 25, 26, 27, 28, 29
const S_DISABLED = 31 # (collections are off: `GC.enable(false)`)
const S_REGS = 192 # (64 words from here: where the registers are saved, while the stack is scanned)
const S_CUR = 32 # per kind and class: the block that is allocated from (2 * NCLASSES words)
const S_PARTIAL = S_CUR + 2 * NCLASSES # and the list of those with free cells

# (`linkonce_odr`, so that the definitions that come with each use of `state` are one global; 256 words)
@inline state() = Base.llvmcall(("""
    @_static_heap_state = linkonce_odr hidden global [256 x i64] zeroinitializer, align 16
    define i64 @state() alwaysinline {
      ret i64 ptrtoint (ptr @_static_heap_state to i64)
    }""", "state"), UInt, Tuple{})

@inline sget(i::Int) = unsafe_load(Ptr{UInt}(state()), i)
@inline sset(i::Int, v::UInt) = unsafe_store!(Ptr{UInt}(state()), v, i)
@inline ld(p::UInt, i::Int) = unsafe_load(Ptr{UInt}(p), i + 1) # the word `i` of memory at `p` (from 0)
@inline st(p::UInt, i::Int, v::UInt) = unsafe_store!(Ptr{UInt}(p), v, i + 1)

# What the program tells the collector (these are weak references, so that code without them, and the host, still link): the data
# that can refer to heap objects, as { count, (address, bytes)... }, and how often to collect (and poison what is freed) to find
# the objects that the collector doesn't know to be in use
@inline roots_table() = Base.llvmcall(("""
    @_static_gc_roots = extern_weak global i64
    define i64 @roots() alwaysinline {
      ret i64 ptrtoint (ptr @_static_gc_roots to i64)
    }""", "roots"), UInt, Tuple{})
@inline stress_interval() = Base.llvmcall(("""
    @_static_gc_stress = extern_weak global i64
    define i64 @stress() alwaysinline {
      ret i64 ptrtoint (ptr @_static_gc_stress to i64)
    }""", "stress"), UInt, Tuple{})

## the stack, and the registers

# the lowest address of the stack that is in use, after the registers have been saved in it (which `_setjmp` does)
@inline stack_pointer() = Base.llvmcall(("""
    declare ptr @llvm.stacksave.p0()
    define i64 @sp() alwaysinline {
      %p = call ptr @llvm.stacksave.p0()
      %i = ptrtoint ptr %p to i64
      ret i64 %i
    }""", "sp"), UInt, Tuple{})
@inline save_registers(buffer::UInt) = Base.llvmcall(("""
    declare i32 @_setjmp(ptr) returns_twice
    define i32 @save(i64 %b) alwaysinline {
      %p = inttoptr i64 %b to ptr
      %r = call i32 @_setjmp(ptr %p)
      ret i32 %r
    }""", "save"), Int32, Tuple{UInt}, buffer)
# the highest address of the stack of the main thread
@static if Sys.isapple()
    @inline stack_base() = Base.llvmcall(("""
        declare ptr @pthread_self()
        declare ptr @pthread_get_stackaddr_np(ptr)
        define i64 @base() alwaysinline {
          %t = call ptr @pthread_self()
          %b = call ptr @pthread_get_stackaddr_np(ptr %t)
          %i = ptrtoint ptr %b to i64
          ret i64 %i
        }""", "base"), UInt, Tuple{})
elseif Sys.islinux()
    @inline stack_base() = Base.llvmcall(("""
        @__libc_stack_end = external global ptr
        define i64 @base() alwaysinline {
          %b = load ptr, ptr @__libc_stack_end
          %i = ptrtoint ptr %b to i64
          ret i64 %i
        }""", "base"), UInt, Tuple{})
else
    stack_base() = UInt(0) # (the stack is not known: the collector can't be used)
end

@noinline function out_of_memory()
    msg = c"Out of memory error"
    GC.@preserve msg @symbolcall puts(pointer(msg)::Ptr{UInt8})::Int32
    @symbolcall exit(Int32(1)::Int32)::Int32
    return nothing
end

@inline function zero_words(p::UInt, nbytes::UInt)
    i = 0
    n = (nbytes >> 3) % Int
    while i < n
        st(p, i, UInt(0))
        i += 1
    end
    return
end

@inline function fill_words(p::UInt, nbytes::UInt, v::UInt)
    i = 0
    n = (nbytes >> 3) % Int
    while i < n
        st(p, i, v)
        i += 1
    end
    return
end

## the allocator that never frees: memory comes from `calloc` in chunks (zero, and not touched until used), from which
## objects are cut one after the other; a large object has a chunk of its own

@noinline function nogc_chunk(n::UInt)
    chunks = sget(S_CHUNKS) + 1
    bytes = sget(S_BYTES) + n
    if n >= LARGE_SIZE
        p = calloc(1, reinterpret(Int, n))
        p == C_NULL && out_of_memory()
        sset(S_BYTES, bytes)
        sset(S_CHUNKS, chunks)
        return UInt(p)
    end
    p = UInt(calloc(1, CHUNK_SIZE))
    p == 0 && out_of_memory()
    sset(S_NOGC_CUR, p + n)
    sset(S_NOGC_STOP, p + CHUNK_SIZE)
    sset(S_BYTES, bytes)
    sset(S_CHUNKS, chunks)
    return p
end

# `gpu_gc_pool_alloc` without a collector: the object of `sz` bytes (after the header), as a pointer
function alloc_nogc(sz::Int, kind::Int)
    sz < 0 && return Ptr{UInt8}(command_nogc(sz))
    n = (reinterpret(UInt, sz) + 0x1f) & ~UInt(0xf) # (the header, and a multiple of 16)
    p = sget(S_NOGC_CUR)
    if p != 0 && n <= sget(S_NOGC_STOP) - p
        sset(S_NOGC_CUR, p + n)
        sset(S_BYTES, sget(S_BYTES) + n)
        return Ptr{UInt8}(p + 16)
    end
    return Ptr{UInt8}(nogc_chunk(n) + 16)
end

# the commands (see `command`) of the heap that doesn't collect: it has nothing to do for most
@noinline function command_nogc(sz::Int)
    sz == HEAP_BYTES && return sget(S_BYTES)
    (sz == COLLECT || sz == LIVE_BYTES || sz == COLLECTIONS) && return UInt(0)
    (sz == DISABLE || sz == ENABLE) && return UInt(1)
    out_of_memory()
    return UInt(0)
end

## size classes: the cell sizes (with the header of the object) are those of a list with steps that get larger

@inline function class_size(c::Int)
    c <= 6 && return UInt(32 + 16c)
    c <= 10 && return UInt(128 + 32 * (c - 6))
    c <= 14 && return UInt(256 + 64 * (c - 10))
    c <= 18 && return UInt(512 + 128 * (c - 14))
    return UInt(1024 + 256 * (c - 18))
end

@inline function size_class(total::UInt)
    total <= 32 && return 0
    total <= 128 && return Int((total - 32 + 15) >> 4)
    total <= 256 && return 6 + Int((total - 128 + 31) >> 5)
    total <= 512 && return 10 + Int((total - 256 + 63) >> 6)
    total <= 1024 && return 14 + Int((total - 512 + 127) >> 7)
    return 18 + Int((total - 1024 + 255) >> 8)
end

## the extents: where there are objects, sorted, as (start, end, header) triples: what an address is in

@noinline function register_extent(start::UInt, stop::UInt, header::UInt)
    n = sget(S_EXT_N) % Int
    cap = sget(S_EXT_CAP) % Int
    ext = sget(S_EXT)
    if n == cap
        newcap = cap == 0 ? 256 : 2 * cap
        new = UInt(calloc(1, newcap * 24))
        new == 0 && out_of_memory()
        i = 0
        while i < 3n
            st(new, i, ld(ext, i))
            i += 1
        end
        ext != 0 && free(Ptr{UInt8}(ext))
        sset(S_EXT, new)
        sset(S_EXT_CAP, newcap % UInt)
        ext = new
    end
    # where it goes: after the extents that start before it
    i = n
    while i > 0 && ld(ext, 3 * (i - 1)) > start
        st(ext, 3i, ld(ext, 3 * (i - 1)))
        st(ext, 3i + 1, ld(ext, 3 * (i - 1) + 1))
        st(ext, 3i + 2, ld(ext, 3 * (i - 1) + 2))
        i -= 1
    end
    st(ext, 3i, start)
    st(ext, 3i + 1, stop)
    st(ext, 3i + 2, header)
    sset(S_EXT_N, (n + 1) % UInt)
    if sget(S_LO) == 0 || start < sget(S_LO)
        sset(S_LO, start)
    end
    if stop > sget(S_HI)
        sset(S_HI, stop)
    end
    return
end

# the index (from 1) of the extent that starts last, at or before `p`, or 0
@inline function find_extent(p::UInt)
    ext = sget(S_EXT)
    lo = 0
    hi = sget(S_EXT_N) % Int
    # (the number of extents that start at or before `p`)
    while lo < hi
        mid = (lo + hi) >> 1
        if ld(ext, 3 * mid) <= p
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

## blocks

@inline bitmap_get(b::UInt, base::Int, i::Int) = (ld(b, base + (i >> 6)) >> (i & 63)) & 1 != 0
@inline function bitmap_set(b::UInt, base::Int, i::Int)
    w = base + (i >> 6)
    st(b, w, ld(b, w) | (UInt(1) << (i & 63)))
    return
end

# a block for the cells of the class `c` and kind: one that has been freed, or the next of the chunk
@noinline function new_block(c::Int, kind::Int)
    b = sget(S_POOL)
    if b != 0
        sset(S_POOL, ld(b, B_NEXT))
        # (it has been used: the cells have to be zero when they are allocated, and the bitmaps are cleared)
        i = B_ALLOC
        while i < B_MARK + BITMAP_WORDS
            st(b, i, UInt(0))
            i += 1
        end
        st(b, B_CLEAN, UInt(0))
    else
        cur = sget(S_CHUNK_CUR)
        if cur == 0 || cur == sget(S_CHUNK_END)
            cur = UInt(calloc(1, CHUNK_BLOCKS * BLOCK_SIZE % Int))
            cur == 0 && out_of_memory()
            sset(S_CHUNK_END, cur + CHUNK_BLOCKS * BLOCK_SIZE)
            sset(S_CHUNKS, sget(S_CHUNKS) + 1)
            sset(S_BYTES, sget(S_BYTES) + CHUNK_BLOCKS * BLOCK_SIZE)
        end
        b = cur
        sset(S_CHUNK_CUR, cur + BLOCK_SIZE)
        st(b, B_CLEAN, UInt(1))
        st(b, B_ALLNEXT, sget(S_BLOCKS))
        sset(S_BLOCKS, b)
        register_extent(b, b + BLOCK_SIZE, b)
    end
    cs = class_size(c)
    st(b, B_TYPE, TYPE_BLOCK)
    st(b, B_CELL, cs)
    st(b, B_NCELLS, (BLOCK_SIZE - HEADER) ÷ cs)
    st(b, B_KIND, kind % UInt)
    st(b, B_CLASS, c % UInt)
    st(b, B_NEXT, UInt(0))
    st(b, B_CURSOR, UInt(0))
    st(b, B_POOLED, UInt(0))
    return b
end

## allocation

# the next cell of the block that is free (the cells that are in use are those of the bitmap, and those before the cursor), or 0
@inline function block_cell(b::UInt)
    i = ld(b, B_CURSOR) % Int
    n = ld(b, B_NCELLS) % Int
    while i < n && bitmap_get(b, B_ALLOC, i)
        i += 1
    end
    i < n || return UInt(0)
    st(b, B_CURSOR, (i + 1) % UInt)
    cs = ld(b, B_CELL)
    cell = b + HEADER + i % UInt * cs
    ld(b, B_CLEAN) == 0 && zero_words(cell, cs) # (what was in it before)
    return cell
end

# whether enough has been allocated since the last collection to do another (and the collector is not busy)
@inline collection_due() = sget(S_SINCE) >= sget(S_THRESHOLD) && sget(S_COLLECTING) == 0 && sget(S_DISABLED) == 0

@noinline function init!()
    sset(S_INIT, UInt(1))
    sset(S_THRESHOLD, MIN_THRESHOLD)
    base = stack_base()
    sset(S_STACK_BASE, base)
    sset(S_SCAN_STACK, base == 0 ? UInt(0) : UInt(1))
    s = stress_interval()
    if s != 0
        sset(S_STRESS, unsafe_load(Ptr{UInt}(s)))
        sset(S_STRESS_LEFT, sget(S_STRESS))
    end
    return
end

# the cell of a small object of the class `c`: from the block that is current, or the next with free cells, or a new one
@noinline function alloc_small_slow(c::Int, kind::Int)
    sget(S_INIT) == 0 && init!()
    idx = kind * NCLASSES + c
    stress = sget(S_STRESS) != 0
    while true
        b = sget(S_CUR + idx)
        if b != 0
            cell = block_cell(b)
            if cell != 0
                stress && sset(S_CUR + idx, UInt(0)) # (every allocation comes here)
                return cell
            end
        end
        if collection_due()
            collect(sget(S_SCAN_STACK) != 0)
            continue # (the blocks that have free cells are not those that there were)
        end
        b = sget(S_PARTIAL + idx)
        if b != 0
            sset(S_PARTIAL + idx, ld(b, B_NEXT))
        else
            b = new_block(c, kind)
        end
        sset(S_SINCE, sget(S_SINCE) + BLOCK_SIZE)
        sset(S_CUR + idx, b)
    end
end

@noinline function alloc_large(total::UInt, kind::Int)
    sget(S_INIT) == 0 && init!()
    if collection_due()
        collect(sget(S_SCAN_STACK) != 0)
    end
    base = UInt(calloc(1, reinterpret(Int, LARGE_HEADER + total)))
    base == 0 && out_of_memory()
    st(base, L_TYPE, TYPE_LARGE)
    st(base, L_SIZE, total)
    st(base, L_KIND, kind % UInt)
    st(base, L_ALLNEXT, sget(S_LARGE))
    sset(S_LARGE, base)
    register_extent(base, base + LARGE_HEADER + total, base)
    sset(S_SINCE, sget(S_SINCE) + total)
    sset(S_BYTES, sget(S_BYTES) + LARGE_HEADER + total)
    return base + LARGE_HEADER
end

# stress mode (see `stress_interval`): collect every so many allocations
@noinline function stress_step()
    left = sget(S_STRESS_LEFT)
    if left <= 1
        sset(S_STRESS_LEFT, sget(S_STRESS))
        sget(S_COLLECTING) == 0 && collect(sget(S_SCAN_STACK) != 0)
    else
        sset(S_STRESS_LEFT, left - 1)
    end
    return
end

# What the program can ask of the heap, as a negative size (which is never that of an allocation), so that the way to the
# allocator is the same: -1 collects, -2 is the number of bytes that were alive after the last collection, -3 the number of
# collections, -4 the bytes that the heap has from the system, -5 and -6 turn collections off and on (the answer is whether they
# were on). The numbers that are the answers are returned as an address.
@noinline function command(sz::Int)
    sz == COLLECT && (collect(sget(S_SCAN_STACK) != 0); return UInt(0))
    sz == LIVE_BYTES && return sget(S_LIVE)
    sz == COLLECTIONS && return sget(S_COLLECTIONS)
    sz == HEAP_BYTES && return sget(S_BYTES)
    if sz == DISABLE || sz == ENABLE
        was = sget(S_DISABLED) == 0 ? UInt(1) : UInt(0)
        sset(S_DISABLED, sz == DISABLE ? UInt(1) : UInt(0))
        return was
    end
    out_of_memory() # (an allocation that is too large)
    return UInt(0)
end

# `gpu_gc_pool_alloc`, with the collector: the object of `sz` bytes (after the header), of the `kind`, as a pointer
function alloc(sz::Int, kind::Int)
    usz = reinterpret(UInt, sz) # (the size of a command is negative, so that it is not small, and `+ 16` doesn't wrap around)
    if usz <= MAX_SMALL - 16
        total = usz + 16
        c = size_class(total)
        b = sget(S_CUR + kind * NCLASSES + c)
        if b != 0
            cell = block_cell(b)
            cell != 0 && return Ptr{UInt8}(cell + 16)
        end
        sget(S_STRESS) != 0 && stress_step()
        return Ptr{UInt8}(alloc_small_slow(c, kind) + 16)
    end
    sz < 0 && return Ptr{UInt8}(command(sz))
    sget(S_STRESS) != 0 && stress_step()
    return Ptr{UInt8}(alloc_large(usz + 16, kind) + 16)
end

## marking

@inline function mark_push(start::UInt, nbytes::UInt)
    n = sget(S_STACK_N) % Int
    if n == sget(S_STACK_CAP) % Int
        cap = n == 0 ? 1024 : 2 * n
        new = UInt(calloc(1, cap * 16))
        new == 0 && out_of_memory()
        old = sget(S_STACK)
        i = 0
        while i < 2n
            st(new, i, ld(old, i))
            i += 1
        end
        old != 0 && free(Ptr{UInt8}(old))
        sset(S_STACK, new)
        sset(S_STACK_CAP, cap % UInt)
    end
    stack = sget(S_STACK)
    st(stack, 2n, start)
    st(stack, 2n + 1, nbytes)
    sset(S_STACK_N, (n + 1) % UInt)
    return
end

# reach the cell `i` of the block, if it is in use
@inline function mark_cell(b::UInt, i::Int)
    i < ld(b, B_NCELLS) % Int || return
    (bitmap_get(b, B_ALLOC, i) || i < ld(b, B_CURSOR) % Int) || return # (not in use)
    bitmap_get(b, B_MARK, i) && return
    bitmap_set(b, B_MARK, i)
    if ld(b, B_KIND) == NORMAL
        cs = ld(b, B_CELL)
        mark_push(b + HEADER + i % UInt * cs + 16, cs - 16)
    end
    return
end

@inline function mark_large(l::UInt)
    ld(l, L_MARK) != 0 && return
    st(l, L_MARK, UInt(1))
    ld(l, L_KIND) == NORMAL && mark_push(l + LARGE_HEADER + 16, ld(l, L_SIZE) - 16)
    return
end

# an address in the extent (index from 1) `e`, as one that a word may hold
@inline function mark_in(e::Int, p::UInt)
    ext = sget(S_EXT)
    p <= ld(ext, 3 * (e - 1) + 1) || return # (just after the end is allowed)
    h = ld(ext, 3 * (e - 1) + 2)
    if ld(h, B_TYPE) == TYPE_BLOCK
        ld(h, B_POOLED) != 0 && return
        data = h + HEADER
        p >= data || return
        cs = ld(h, B_CELL)
        i = ((p - data) ÷ cs) % Int
        mark_cell(h, i)
        # at the start of a cell it may be just after the cell before
        i > 0 && (p - data) == i % UInt * cs && mark_cell(h, i - 1)
    else
        p >= h + LARGE_HEADER && mark_large(h)
    end
    return
end

# `p`, a word that may be a reference: reach what it is in
@inline function mark_word(p::UInt)
    (p < sget(S_LO) || p > sget(S_HI)) && return
    e = find_extent(p)
    e > 0 && mark_in(e, p)
    # (an address that is the start of an extent may be just after the one before)
    if e > 1 && p == ld(sget(S_EXT), 3 * (e - 1))
        mark_in(e - 1, p)
    end
    return
end

# the words of memory from `lo` to `hi`
@inline function scan(lo::UInt, hi::UInt)
    p = (lo + 7) & ~UInt(7)
    while p + 8 <= hi
        mark_word(unsafe_load(Ptr{UInt}(p)))
        p += 8
    end
    return
end

# reach everything that what is on the mark stack refers to
@noinline function drain()
    while sget(S_STACK_N) != 0
        n = sget(S_STACK_N) - 1
        sset(S_STACK_N, n)
        stack = sget(S_STACK)
        start = ld(stack, 2 * (n % Int))
        nbytes = ld(stack, 2 * (n % Int) + 1)
        scan(start, start + nbytes)
    end
    return
end

## sweeping

# keep what was reached: the cells in use are now those, and nothing is reached; the blocks without any are freed
@noinline function sweep()
    poison = sget(S_STRESS) != 0
    for idx in 0:2*NCLASSES-1
        sset(S_CUR + idx, UInt(0))
        sset(S_PARTIAL + idx, UInt(0))
    end
    live = UInt(0)
    b = sget(S_BLOCKS)
    while b != 0
        if ld(b, B_POOLED) == 0
            cs = ld(b, B_CELL)
            n = ld(b, B_NCELLS) % Int
            nwords = (n + 63) >> 6
            count = 0
            w = 0
            while w < nwords
                m = ld(b, B_MARK + w)
                count += count_ones(m)
                if poison # the cells that are freed have what is in them destroyed (so that a use of one is seen)
                    old = ld(b, B_ALLOC + w)
                    cursor_cells = ld(b, B_CURSOR) % Int
                    j = 0
                    while j < 64 && 64w + j < n
                        i = 64w + j
                        inuse = ((old >> j) & 1) != 0 || i < cursor_cells
                        if inuse && ((m >> j) & 1) == 0
                            fill_words(b + HEADER + i % UInt * cs, cs, 0xdddddddddddddddd)
                        end
                        j += 1
                    end
                end
                st(b, B_ALLOC + w, m)
                st(b, B_MARK + w, UInt(0))
                w += 1
            end
            st(b, B_CURSOR, UInt(0))
            st(b, B_CLEAN, UInt(0))
            live += count % UInt * cs
            if count == 0
                st(b, B_POOLED, UInt(1))
                st(b, B_NEXT, sget(S_POOL))
                sset(S_POOL, b)
            elseif count < n
                idx = ld(b, B_KIND) % Int * NCLASSES + ld(b, B_CLASS) % Int
                st(b, B_NEXT, sget(S_PARTIAL + idx))
                sset(S_PARTIAL + idx, b)
            end
        end
        b = ld(b, B_ALLNEXT)
    end
    # the large objects that were not reached are freed
    prev = UInt(0)
    l = sget(S_LARGE)
    while l != 0
        nxt = ld(l, L_ALLNEXT)
        if ld(l, L_MARK) == 0
            prev == 0 ? sset(S_LARGE, nxt) : st(prev, L_ALLNEXT, nxt)
            remove_extent(l)
            sset(S_BYTES, sget(S_BYTES) - (LARGE_HEADER + ld(l, L_SIZE)))
            free(Ptr{UInt8}(l))
        else
            st(l, L_MARK, UInt(0))
            live += ld(l, L_SIZE)
            prev = l
        end
        l = nxt
    end
    return live
end

@noinline function remove_extent(header::UInt)
    ext = sget(S_EXT)
    n = sget(S_EXT_N) % Int
    i = 0
    while i < n && ld(ext, 3i + 2) != header
        i += 1
    end
    i < n || return
    while i + 1 < n
        st(ext, 3i, ld(ext, 3 * (i + 1)))
        st(ext, 3i + 1, ld(ext, 3 * (i + 1) + 1))
        st(ext, 3i + 2, ld(ext, 3 * (i + 1) + 2))
        i += 1
    end
    sset(S_EXT_N, (n - 1) % UInt)
    return
end

## collecting

# scan the data that the program has told us about
@inline function scan_roots()
    table = roots_table()
    if table != 0
        n = ld(table, 0) % Int
        i = 0
        while i < n
            addr = ld(table, 1 + 2i)
            scan(addr, addr + ld(table, 2 + 2i))
            i += 1
        end
    end
    xr = sget(S_XROOTS)
    xr != 0 && scan(xr, xr + sget(S_XROOTS_N) * 8)
    return
end

# Free what nothing refers to. `scan_stack`: whether the stack and the registers are looked at, which the program needs (and
# a test of the collector, which has the roots it chooses, does not).
@noinline function collect(scan_stack::Bool)
    sget(S_INIT) == 0 && init!()
    sset(S_COLLECTING, UInt(1))
    scan_roots()
    if scan_stack
        # the registers are saved in the state (a buffer in memory that is not the stack), and the stack is from here to the base
        buffer = state() + (S_REGS - 1) * 8
        save_registers(buffer)
        scan(buffer, buffer + 512)
        scan(stack_pointer(), sget(S_STACK_BASE))
    end
    drain()
    live = sweep()
    sset(S_LIVE, live)
    sset(S_COLLECTIONS, sget(S_COLLECTIONS) + 1)
    sset(S_SINCE, UInt(0))
    sset(S_THRESHOLD, max(MIN_THRESHOLD, live))
    sset(S_COLLECTING, UInt(0))
    return
end

# for tests of the collector: when it collects by itself (the bytes allocated between collections: more than is ever allocated
# means never), and whether it looks at the stack
function configure(threshold::UInt, scan_stack::Int)
    sget(S_INIT) == 0 && init!()
    sset(S_THRESHOLD, threshold)
    sset(S_SCAN_STACK, scan_stack % UInt)
    return
end

# a collection when called by the program or a test: of what is not used, the stack and registers included or not
function collect_now(scan_stack::Int)
    collect(scan_stack != 0)
    return
end

end # module Heap
