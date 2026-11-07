# The heap that allocation comes from, and the garbage collector (src/heap.jl): the allocators themselves, on the host, and
# what they do to programs. Included by runtests.jl, after corpus.jl has loaded StaticCompilerOverrides.
using Test, Random

const Heap = StaticCompilerOverrides.Runtime.Heap

@testset "Heap: allocator that never frees" begin
    sizes = [0, 1, 8, 15, 16, 17, 100, 1000, 70_000, 300_000, 2_000_000, 24, 24, 24]
    before = Heap.sget(Heap.S_BYTES)
    ptrs = [Heap.alloc_nogc(sz, Heap.NORMAL) for sz in sizes]
    # 16-byte aligned (as objects are), with room for the header of 16 bytes, and distinct
    @test all(p -> UInt(p) % 16 == 0, ptrs)
    @test length(unique(ptrs)) == length(ptrs)
    # the bytes that were handed out: the header, and the size rounded up to 16
    @test Heap.sget(Heap.S_BYTES) - before == sum(sz -> (sz + 31) & ~15, sizes)
    # zero, and not overlapping: each is written to the end, and read back after all were
    @test all(((p, sz),) -> sz == 0 || all(i -> unsafe_load(p, i) == 0x00, 1:sz), zip(ptrs, sizes))
    for (k, (p, sz)) in enumerate(zip(ptrs, sizes))
        sz > 0 && foreach(i -> unsafe_store!(p, UInt8(k), i), 1:sz)
    end
    @test all(k -> sizes[k] == 0 || all(i -> unsafe_load(ptrs[k], i) == UInt8(k), 1:sizes[k]), eachindex(sizes))
    # an object that doesn't fit in the chunk starts the next one
    chunks = Heap.sget(Heap.S_CHUNKS)
    Heap.alloc_nogc(Heap.CHUNK_SIZE, Heap.NORMAL)
    @test Heap.sget(Heap.S_CHUNKS) == chunks + 1
end

# The collector, with the roots that a test chooses (and not the stack, which the host's Julia has its own references on): graphs of
# objects of random sizes, kinds and references (also to the inside of objects), of which the oracle knows what is reached
@testset "Heap: collector" begin
    cell_bytes(sz) = (total = UInt(sz) + 16; total <= Heap.MAX_SMALL ? Heap.class_size(Heap.size_class(total)) : total)
    struct Node
        ptr::UInt
        size::Int
        atomic::Bool
        id::UInt
    end
    function make_node(rng, id, kind)
        sz = rand(rng) < 0.03 ? rand(rng, 5000:60000) : rand(rng, 16:3000)
        sz = (sz ÷ 8) * 8
        p = UInt(Heap.alloc(sz, kind))
        p % 16 == 0 && all(i -> unsafe_load(Ptr{UInt}(p), i) == 0, 1:sz÷8) || error("not aligned and zero")
        unsafe_store!(Ptr{UInt}(p), 0xC0DE000000000000 | id, 1)
        return Node(p, sz, kind == Heap.ATOMIC, id)
    end
    function round_of(rng; n = 1500, nroots = 25)
        Heap.configure(typemax(UInt) >> 1, 0) # (it doesn't collect by itself while the graph is made)
        nodes = [make_node(rng, UInt(id), rand(rng) < 0.3 ? Heap.ATOMIC : Heap.NORMAL) for id in 1:n]
        slots = [Dict{Int,Int}() for _ in 1:n] # (what a slot holds is the last edge stored in it)
        for (i, node) in enumerate(nodes)
            node.atomic && continue
            nw = node.size ÷ 8
            nw >= 2 || continue
            for _ in 1:rand(rng, 0:3)
                j = rand(rng, 1:n)
                target = nodes[j]
                off = rand(rng) < 0.5 ? 0 : 8 * rand(rng, 0:max(target.size ÷ 8 - 1, 0)) # (also into the object)
                slot = rand(rng, 2:nw)
                unsafe_store!(Ptr{UInt}(node.ptr), target.ptr + off, slot)
                slots[i][slot] = j
            end
        end
        for node in nodes # (the addresses that an object that can't refer to others holds are not references)
            node.atomic && node.size >= 16 && unsafe_store!(Ptr{UInt}(node.ptr), rand(rng, nodes).ptr, rand(rng, 2:node.size÷8))
        end
        edges = [collect(values(d)) for d in slots]
        roots = rand(rng, 1:n, nroots)
        xr = Ptr{UInt}(Libc.calloc(nroots, 8))
        for (k, r) in enumerate(roots)
            unsafe_store!(xr, nodes[r].ptr + (rand(rng) < 0.3 ? 8 * rand(rng, 0:max(nodes[r].size ÷ 8 - 1, 0)) : 0), k)
        end
        Heap.sset(Heap.S_XROOTS, UInt(xr)); Heap.sset(Heap.S_XROOTS_N, UInt(nroots))
        seen = falses(n)
        stack = unique(roots)
        foreach(r -> seen[r] = true, stack)
        while !isempty(stack)
            for j in edges[pop!(stack)]
                seen[j] || (seen[j] = true; push!(stack, j))
            end
        end
        expected = sum(cell_bytes(nodes[i].size) for i in 1:n if seen[i])
        Heap.collect_now(0)
        live = Heap.sget(Heap.S_LIVE)
        # the memory that was freed is used by what is allocated now, and what is alive has to be as it was
        for _ in 1:1000
            p = UInt(Heap.alloc(rand(rng, 16:600), rand(rng) < 0.5 ? Heap.ATOMIC : Heap.NORMAL))
            unsafe_store!(Ptr{UInt}(p), 0xBAD0BAD0BAD0BAD0, 1); unsafe_store!(Ptr{UInt}(p), 0xBAD0BAD0BAD0BAD0, 2)
        end
        lost = count(i -> seen[i] && unsafe_load(Ptr{UInt}(nodes[i].ptr), 1) != (0xC0DE000000000000 | nodes[i].id), 1:n)
        Libc.free(xr); Heap.sset(Heap.S_XROOTS, UInt(0)); Heap.sset(Heap.S_XROOTS_N, UInt(0))
        return live, expected, lost, count(seen)
    end
    rng = MersenneTwister(2024)
    @testset "random graph $k" for k in 1:5
        live, expected, lost, reached = round_of(rng)
        @test lost == 0           # nothing that is reached was freed
        @test live == expected    # and nothing else is kept (what an atomic object holds is not a reference)
        @test reached > 0
    end

    @testset "what keeps an object" begin
        Heap.configure(typemax(UInt) >> 1, 0)
        Heap.collect_now(0) # (what is there is not alive: the roots are chosen)
        base = Heap.sget(Heap.S_LIVE)
        keep(words) = (xr = Ptr{UInt}(Libc.calloc(length(words), 8)); foreach(((i, w),) -> unsafe_store!(xr, w, i), enumerate(words));
                       Heap.sset(Heap.S_XROOTS, UInt(xr)); Heap.sset(Heap.S_XROOTS_N, UInt(length(words))); xr)
        release(xr) = (Heap.sset(Heap.S_XROOTS, UInt(0)); Heap.sset(Heap.S_XROOTS_N, UInt(0)); Libc.free(xr))
        a = UInt(Heap.alloc(200, Heap.NORMAL)); b = UInt(Heap.alloc(200, Heap.ATOMIC)); c = UInt(Heap.alloc(100_000, Heap.NORMAL))
        # the address of an object, or of the inside of it, keeps it
        xr = keep([a + 8, b + 100, c + 50_000])
        Heap.collect_now(0)
        @test Heap.sget(Heap.S_LIVE) == cell_bytes(200) * 2 + cell_bytes(100_000)
        release(xr)
        # an address just after the end of an object does (a loop over an array that has gone past its end)
        xr = keep([a + 200])
        Heap.collect_now(0)
        @test Heap.sget(Heap.S_LIVE) >= cell_bytes(200)
        release(xr)
        # a number that is not an address of the heap does not
        xr = keep([UInt(12345), UInt(0xdeadbeef), UInt(1) << 62, ~UInt(0)])
        Heap.collect_now(0)
        @test Heap.sget(Heap.S_LIVE) == 0
        release(xr)
        # an object that refers to another keeps it, if it can refer to others, and does not if it can't
        t = UInt(Heap.alloc(64, Heap.NORMAL))
        m = UInt(Heap.alloc(64, Heap.ATOMIC)); unsafe_store!(Ptr{UInt}(m), t, 2) # (an atomic object that holds the address of `t`)
        xr = keep([m])
        Heap.collect_now(0)
        @test Heap.sget(Heap.S_LIVE) == cell_bytes(64)      # only the atomic one
        release(xr)
        # (n1 and t were freed by that: new ones)
        t = UInt(Heap.alloc(64, Heap.NORMAL)); n1 = UInt(Heap.alloc(64, Heap.NORMAL)); unsafe_store!(Ptr{UInt}(n1), t, 2)
        xr = keep([n1])
        Heap.collect_now(0)
        @test Heap.sget(Heap.S_LIVE) == 2 * cell_bytes(64)  # n1 and t
        release(xr)
        # what is freed is used again, and what is large is returned to the system
        Heap.collect_now(0)
        @test Heap.sget(Heap.S_LIVE) == 0
        big_before = Heap.sget(Heap.S_BYTES)
        for _ in 1:20
            Heap.alloc(1_000_000, Heap.ATOMIC)
        end
        Heap.collect_now(0)
        @test Heap.sget(Heap.S_BYTES) < big_before + 1_000_000  # the 20 are freed
    end
end

# compile and run a program, and what it prints
function run_heap_program(main; kwargs...)
    exe = compile_executable(main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)); kwargs...)
    return readchomp(`$exe`)
end

# a global that is a container, which can be changed to refer to objects that are made later: it has to be looked at
const HEAP_KEEP = Any[]
const HEAP_REF = Ref{Any}(nothing)
mutable struct HeapNode; v::Int; next::Union{HeapNode,Nothing}; end
@noinline heap_message(i) = string("e", i)

@testset "Heap: programs with the collector" begin
    # the same results as Julia with the collector that collects often (and one that overwrites what it frees)
    @testset "programs, gc = $gc" for gc in (true, 3)
        many() = (keep = Vector{Vector{Int}}(); for i in 1:3000; v = Vector{Int}(undef, 1 + i % 37); fill!(v, i); push!(keep, v); end;
                  s = 0; for i in 1:3000; s += keep[i][1] + keep[i][end] + length(keep[i]); end; s)
        @test static_result(many; gc) == many()
        large() = (a = zeros(Int, 300_000); a[1] = 3; a[end] = 4; sum(a) + length(a))
        @test static_result(large; gc) == large()
        grow() = (v = Int[]; for i in 1:2000; push!(v, i); end; d = Dict{Int,String}(); for i in 1:200; d[i] = string(i); end;
                  sum(v) + sum(length, values(d)))
        @test static_result(grow; gc) == grow()
        strings() = (s = ""; for i in 1:60; s = string(s, i); end; length(s) + sum(length(string(i, "x")) for i in 1:200))
        @test static_result(strings; gc) == strings()
        # objects that are only reached through other objects, and through a global that is changed
        chain() = (head = nothing; for i in 1:500; head = HeapNode(i, head); end; c = 0; x = head; while x !== nothing; c += x.v; x = x.next; end; c)
        @test static_result(chain; gc) == chain()
        globals() = (empty!(HEAP_KEEP); for i in 1:300; push!(HEAP_KEEP, string("g", i)); [i, i]; end;
                     HEAP_REF[] = [1.5, 2.5]; GC.gc(); s = 0; for x in HEAP_KEEP; s += length(x::String); end; s + Int(sum(HEAP_REF[]::Vector{Float64})))
        @test static_result(globals; gc) == globals()
        # exceptions: the object that is thrown is reached through the runtime's state, and not through anything else
        thrown() = (c = 0; for i in 1:200; msg = heap_message(i); c += try; throw(ErrorException(msg)); catch e; e isa ErrorException ? length(e.msg) : 0; end; end; c)
        @test static_result(thrown; gc) == thrown()
    end

    @testset "memory does not grow" begin
        # a program that makes a great deal of garbage keeps the heap small (and Julia's `GC.gc` is the collector's)
        function bounded(argc::Int, argv::Ptr{Ptr{UInt8}})
            s = 0
            for i in 1:3_000_000
                v = Base.inferencebarrier(Vector{Int}(undef, 4 + (i & 3)))::Vector{Int}
                v[1] = i
                s += v[1]
            end
            GC.gc()
            printf(c"%d %d %d\n", gc_collections() > 0, gc_heap_bytes() < 64 << 20, gc_live_bytes() < 1 << 20)
            return 0
        end
        @test run_heap_program(bounded; gc = true) == "1 1 1"
        # and without it, it grows (which is what `gc = false` is: nothing is freed)
        @test run_heap_program(bounded; gc = false) == "0 0 1"
        function disabled(argc::Int, argv::Ptr{Ptr{UInt8}})
            was = GC.enable(false)
            before = gc_collections()
            for i in 1:2_000_000
                Base.inferencebarrier(Vector{Int}(undef, 8))
            end
            during = gc_collections() - before
            now_on = GC.enable(true)
            printf(c"%d %d %d\n", was, during, now_on)
            return 0
        end
        @test run_heap_program(disabled; gc = true) == "1 0 0"
    end
end

# A library (`compile_shlib`) is called from the stack that the caller has: a task that runs on another thread of Julia has one of
# its own, where the references of the library are not found by looking at the stack of the thread that made the first allocation,
# and what the collector would free would be in use. So it frees nothing there (and the program goes on). That needs a Julia
# with threads, so it is done by one that is started with two.
@testset "Heap: a library called from a task on another thread" begin
    script = joinpath(mktempdir(), "shlib_thread.jl")
    write(script, raw"""
        using Libdl: dlopen, dlsym, dlext
        using StaticCompilerOverrides
        function churn_vectors(n::Int)
            v = Vector{Vector{Int}}()
            s = 0
            for i in 1:n
                push!(v, [i, i + 1, i + 2])
                length(v) > 50 && (s += v[1][2]; popfirst!(v))
            end
            return s + length(v)
        end
        dir = mktempdir()
        compile_shlib(churn_vectors, (Int,), dir, "libchurn"; gc = 3) # (the collector runs as often as it can)
        f = dlsym(dlopen(joinpath(dir, "libchurn.$dlext")), "churn_vectors")
        expected = churn_vectors(5_000)
        results = Bool[ccall(f, Int, (Int,), 5_000) == expected] # (on the stack of the thread)
        for _ in 1:3
            push!(results, fetch(Threads.@spawn ccall(f, Int, (Int,), 5_000)) == expected) # (on that of a task, on another thread)
        end
        print(all(results) ? "ok" : "wrong")
        """)
    cmd = `$(Base.julia_cmd()) -t 2 --project=$(Base.active_project()) $script`
    errors = tempname()
    out = read(ignorestatus(pipeline(cmd; stderr = errors)), String)
    isempty(out) && print(stderr, read(errors, String))
    @test endswith(out, "ok")
end
