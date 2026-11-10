# DataStructures.jl: stacks, queues and heaps, dictionaries of different kinds, sorted containers, disjoint sets, lists and trees. (The trees keep `Union{Node,Nothing}` fields, whose fields
# are read and written through the part of the union that is not `Nothing`: see the tests of unions in `core/language.jl`.)
using DataStructures

@testset "DataStructures.jl" begin
    @testset "Stacks, queues and deques" begin
        check_cases([
            "Stack"             => @opaque(() -> (s = Stack{Int}(); for i in 1:5; push!(s, i); end; pop!(s) + first(s) + length(s))),
            "Queue"             => @opaque(() -> (q = Queue{Int}(); for i in 1:5; push!(q, i); end; popfirst!(q) * 10 + first(q) + length(q))),
            "Deque"             => @opaque(() -> (d = Deque{Int}(); for i in 1:5; push!(d, i); pushfirst!(d, -i); end; pop!(d) + popfirst!(d) + length(d) + first(d))),
            "CircularBuffer"    => @opaque(() -> (b = CircularBuffer{Int}(3); for i in 1:5; push!(b, i); end; sum(b) * 10 + length(b) + first(b))),
            "CircularDeque"     => @opaque(() -> (d = CircularDeque{Int}(4); for i in 1:6; length(d) == 4 && popfirst!(d); push!(d, i); end; first(d) * 10 + last(d) + length(d))),
            "MutableLinkedList" => @opaque(() -> (l = MutableLinkedList{Int}(); for i in 1:5; push!(l, i); pushfirst!(l, -i); end; length(l) * 100 + first(l) + last(l))),
            "list"              => @opaque(() -> (l = list(1, 2, 3); length(l) * 10 + head(l) + head(tail(l)))),
        ])
    end

    @testset "Heaps and priority queues" begin
        check_cases([
            "BinaryMinHeap"        => @opaque(() -> (h = BinaryMinHeap{Int}(); for i in (5, 3, 8, 1); push!(h, i); end; pop!(h) * 10 + first(h))),
            "BinaryMaxHeap"        => @opaque(() -> (h = BinaryMaxHeap([3, 9, 2]); pop!(h) * 10 + first(h))),
            "heap sort"            => @opaque(() -> (h = BinaryMinHeap([5, 2, 9, 1, 7]); s = 0; while !isempty(h); s = s * 10 + pop!(h); end; s)),
            "custom order"         => @opaque(() -> pop!(BinaryHeap(Base.Order.Reverse, [3, 1, 2]))),
            "MutableBinaryMinHeap" => @opaque(() -> (h = MutableBinaryMinHeap{Int}(); i1 = push!(h, 5); push!(h, 2); DataStructures.update!(h, i1, 1); top_with_handle(h)[1] * 10 + length(h))),
            "heapify!, heappush!"  => @opaque(() -> (v = [5, 2, 9, 1]; heapify!(v); heappush!(v, 0); heappop!(v) * 10 + heappop!(v))),
            "nlargest, nsmallest"  => @opaque(() -> (v = [5, 1, 9, 3, 7]; sum(nlargest(2, v)) * 10 + sum(nsmallest(2, v)))),
            "PriorityQueue"        => @opaque(() -> (q = PriorityQueue{Int,Int}(); q[1] = 5; q[2] = 1; q[3] = 3; popfirst!(q).first * 10 + first(q).first)),
            "PriorityQueue of Symbols" => @opaque(() -> (q = PriorityQueue{Symbol,Float64}(); q[:a] = 2.0; q[:b] = 1.0; Int(q[:a]) + length(q) * 10)),
        ])
        # (the methods that are deprecated, and that a package that was written before still calls: Julia warns, the program does not)
        @test static_result(@opaque(() -> (q = PriorityQueue{Int,Int}(); q[1] = 5; q[2] = 1; peek(q)[1]))) == 2
        @test static_result(@opaque(() -> (q = PriorityQueue{Int,Int}(); q[1] = 5; q[2] = 1; dequeue!(q)))) == 2
    end

    @testset "Dictionaries and counters" begin
        check_cases([
            "DefaultDict"       => @opaque(() -> (d = DefaultDict{Int,Int}(0); for i in 1:10; d[i % 3] += i; end; d[0] + d[1] * 100 + length(d))),
            "DefaultDict of words" => @opaque(() -> (d = DefaultDict{String,Int}(0); for w in split("a b a c b a"); d[w] += 1; end; d["a"] * 10 + d["b"])),
            "counter"           => @opaque(() -> (a = counter(Int); for x in (1, 2, 1, 3, 1); push!(a, x); end; a[1] * 10 + a[2] + length(a))),
            "counter of words"  => @opaque(() -> (a = counter(split("x y x z x")); a["x"] * 10 + a["y"])),
            "inc!, reset!"      => @opaque(() -> (a = counter(Int); for x in (1, 2, 1); inc!(a, x, 2); end; reset!(a, 2); a[1] + length(a))),
            "OrderedDict"       => @opaque(() -> (d = OrderedDict{Int,Int}(); d[3] = 1; d[1] = 2; d[2] = 3; sum(k * 10^i for (i, k) in enumerate(keys(d))))),
            "OrderedDict merge" => @opaque(() -> (d = OrderedDict(1 => 2); d2 = merge(d, OrderedDict(3 => 4)); sum(values(d2)) + length(d2))),
            "OrderedSet"        => @opaque(() -> (s = OrderedSet{Int}(); for i in (3, 1, 3, 2); push!(s, i); end; sum(x * 10^i for (i, x) in enumerate(s)))),
            "RobinDict"         => @opaque(() -> (d = RobinDict{Int,Int}(); for i in 1:50; d[i] = i * 2; end; for i in 1:2:50; delete!(d, i); end; length(d) + d[10] + sum(values(d)))),
            "SwissDict"         => @opaque(() -> (d = SwissDict{Int,Int}(); for i in 1:50; d[i] = i * 2; end; for i in 1:2:50; delete!(d, i); end; length(d) + d[10] + sum(values(d)))),
            "OrderedRobinDict"  => @opaque(() -> (d = OrderedRobinDict{Int,Int}(); for i in (3, 1, 2); d[i] = i; end; sum(k * 10^j for (j, k) in enumerate(keys(d))))),
            "MultiDict"         => @opaque(() -> (d = MultiDict{Int,Int}(); insert!(d, 1, 10); insert!(d, 1, 20); insert!(d, 2, 5); length(d[1]) * 100 + sum(d[1]))),
            "SparseIntSet"      => @opaque(() -> (s = SparseIntSet(); for i in (5, 1000, 3); push!(s, i); end; length(s) * 10 + Int(3 in s) + sum(s) % 7)),
            "DiBitVector"       => @opaque(() -> (v = DiBitVector(10, 0); v[3] = 2; v[4] = 3; Int(v[3]) * 10 + Int(v[4]))),
        ])
    end

    @testset "Sorted containers" begin
        check_cases([
            "SortedDict"        => @opaque(() -> (d = SortedDict{Int,Int}(); for i in (5, 2, 8, 1); d[i] = i * i; end; sum(k * 10^i for (i, k) in enumerate(keys(d))))),
            "SortedSet"         => @opaque(() -> (s = SortedSet{Int}(); for i in (5, 2, 8, 2); push!(s, i); end; first(s) * 100 + length(s))),
            "SortedSet algebra" => @opaque(() -> (a = SortedSet([1, 3, 5]); b = SortedSet([3, 4, 5]); length(union(a, b)) * 10 + length(intersect(a, b)))),
            "SortedMultiDict"   => @opaque(() -> (d = SortedMultiDict{Int,Int}(); insert!(d, 2, 1); insert!(d, 1, 2); insert!(d, 2, 3); length(d) * 10 + first(d)[1])),
            "searching by semitoken" => @opaque(() -> (d = SortedDict{Int,Int}(); for i in 1:10; d[i * 2] = i; end; t = searchsortedfirst(d, 7); deref_value((d, t)) * 100 + deref_key((d, searchsortedlast(d, 9))))),
            "iterating a range" => @opaque(() -> (d = SortedDict{Int,Int}(); for i in 1:10; d[i] = i * i; end; sum(v for (k, v) in d if k > 3) + length(collect(inclusive(d, searchsortedfirst(d, 2), searchsortedlast(d, 5)))))),
            "many insertions"   => @opaque(() -> (s = SortedSet{Int}(); for i in 1:20; push!(s, (i * 7) % 11); end; sum(i * x for (i, x) in enumerate(s)))),
        ])
    end

    @testset "Disjoint sets and Fenwick trees" begin
        check_cases([
            "IntDisjointSet"    => @opaque(() -> (s = IntDisjointSet(10); union!(s, 1, 2); union!(s, 2, 3); union!(s, 5, 6); Int(in_same_set(s, 1, 3)) + 10 * num_groups(s))),
            "DisjointSet"       => @opaque(() -> (s = DisjointSet{Int}(1:6); union!(s, 1, 2); union!(s, 3, 4); union!(s, 2, 3); Int(in_same_set(s, 1, 4)) + 10 * num_groups(s))),
            "FenwickTree"       => @opaque(() -> (f = FenwickTree{Int}(10); for i in 1:10; inc!(f, i, i); end; prefixsum(f, 5))),
        ])
        @test static_result(@opaque(() -> (s = IntDisjointSets(10); union!(s, 1, 2); num_groups(s)))) == 9 # (a deprecated binding: Julia warns, the program does not)
    end

    # (nodes that have `Union{Node,Nothing}` fields, and are read and written through them)
    @testset "Balanced trees" begin
        check_cases([
            "AVLTree"   => @opaque(() -> (t = AVLTree{Int}(); for i in (5, 2, 8, 1, 9, 3); push!(t, i); end; length(t) * 10 + Int(haskey(t, 8)) + Int(haskey(t, 4)))),
            "RBTree"    => @opaque(() -> (t = RBTree{Int}(); for i in (5, 2, 8, 1, 9, 3); push!(t, i); end; length(t) * 10 + Int(haskey(t, 8)) + Int(haskey(t, 4)))),
            "SplayTree" => @opaque(() -> (t = SplayTree{Int}(); for i in (5, 2, 8, 1, 9, 3); push!(t, i); end; length(t) * 10 + Int(haskey(t, 8)) + Int(haskey(t, 4)))),
            "AVLTree: many insertions" => @opaque(() -> (t = AVLTree{Int}(); for i in 1:200; push!(t, (i * 37) % 101); end; length(t))),
        ])
    end
end
