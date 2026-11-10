# `finalizer(f, x)` of a Julia function in a compiled program: the collector finds the object unreachable, and the program runs `f` on it.
# (Each program is compiled and run, and its output is looked at: when the collector runs is not the same as in Julia, so the programs are not compared with Julia.)

mutable struct FinRes; id::Int; end
const FIN_FREED = Ref(0)
const FIN_SUM = Ref(0)
const FIN_LOG = Int[]
const FIN_KEEP = Ref{Any}(nothing)

# (the objects are made in functions that have returned when the collector runs. The collector is conservative, so an object that a word of the stack, or of the
# memory that the collector keeps, happens to have the address of is not freed by that collection: a few of the last ones may survive, and the tests allow for that,
# and for nothing else: an object is never finalized twice, and the ones that are not reachable are all finalized (but those).)
@noinline function make_with_allocation(n)
    for i in 1:n
        r = FinRes(i)
        finalizer(x -> (push!(FIN_LOG, x.id); v = collect(1:50); FIN_FREED[] += length(v)), r)
    end
end
const FIN_A, FIN_B, FIN_C = Ref(0), Ref(0), Ref(0)
@noinline function make_of_types(n)
    for i in 1:n
        a = FinRes(i)
        finalizer(x -> (FIN_A[] += 1), a)
        b = FinOther("x")
        finalizer(x -> (FIN_B[] += 1), b)
        k = i
        c = FinRes(i)
        finalizer(x -> (FIN_C[] += k), c) # (a closure with a captured value)
    end
end
mutable struct FinOther; name::String; end

function run_fin_program(f)
    dir = mktempdir()
    exe = compile_executable(f, (Vector{String},), dir, "fin_program")
    return read(`$exe`, String)
end

@testset "Finalizers" begin
    @testset "run for the objects that are unreachable, and only those" begin
        function many(args::Vector{String})
            for i in 1:2000
                r = FinRes(i)
                finalizer(x -> (FIN_FREED[] += 1; FIN_SUM[] += x.id), r)
            end
            keep = FinRes(7)
            finalizer(x -> (FIN_FREED[] += 100000), keep)
            GC.gc()
            println(FIN_FREED[], " ", FIN_SUM[], " ", keep.id)
            return 0
        end
        freed, ids, kept = parse.(Int, split(run_fin_program(many)))
        @test 1998 <= freed <= 2000 # (and not the 100000 of `keep`)
        @test sum(1:2000) - 2 * 2000 <= ids <= sum(1:2000)
        @test kept == 7
    end

    @testset "a finalizer that allocates" begin
        function allocating(args::Vector{String})
            make_with_allocation(300)
            GC.gc()
            println(length(FIN_LOG), " ", FIN_FREED[])
            return 0
        end
        n, total = parse.(Int, split(run_fin_program(allocating)))
        @test 298 <= n <= 300
        @test total == 50n
    end

    @testset "a finalizer that throws is ignored" begin
        function throwing(args::Vector{String})
            for i in 1:10
                r = FinRes(i)
                finalizer(x -> error("in a finalizer"), r)
            end
            GC.gc()
            println("done")
            return 0
        end
        @test run_fin_program(throwing) == "done\n"
    end

    @testset "a finalizer that keeps the object (resurrection) is run once, and the object stays valid" begin
        function resurrecting(args::Vector{String})
            r = FinRes(42)
            finalizer(x -> (FIN_KEEP[] = x; FIN_FREED[] += 1), r)
            r = nothing
            GC.gc()
            GC.gc()
            kept = FIN_KEEP[]
            println(FIN_FREED[], " ", kept === nothing ? -1 : (kept::FinRes).id)
            return 0
        end
        out = run_fin_program(resurrecting)
        @test out == "1 42\n" || out == "0 -1\n" # (a stale value of the stack may keep the object: it is conservative)
    end

    @testset "different types of closure and object" begin
        function types(args::Vector{String})
            make_of_types(100)
            GC.gc()
            println(FIN_A[], " ", FIN_B[], " ", FIN_C[])
            return 0
        end
        a, b, c = parse.(Int, split(run_fin_program(types)))
        @test 98 <= a <= 100
        @test 98 <= b <= 100
        @test sum(1:100) - 2 * 100 <= c <= sum(1:100)
    end
end
