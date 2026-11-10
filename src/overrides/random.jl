# Random numbers without tasks.
#
# Julia's default RNG (`Random.default_rng()`, a `TaskLocalRNG`) keeps its xoshiro256++ state in
# fields of the current task, and compiled programs have no tasks. We keep the state in a global
# instead (so there is a single, process-wide stream), seeded from the operating system's
# entropy source the first time it is used, as Julia seeds each new process randomly.
# `Random.seed!` works as usual, since it only goes through `setstate!`.

using Random: Random, TaskLocalRNG

# xoshiro256++ state (s0..s3) and the splitmix state `s4`. All zero means "not seeded yet",
# which is not a valid xoshiro state.
const TASKLOCAL_RNG_STATE = Ref{NTuple{5,UInt64}}((0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000))

# four words of entropy from libc. If the system can't provide it that is an error: a generator with a fixed seed would give the same numbers each
# time that the program runs, which is not what `rand()` is. (`Random.seed!` makes one that is meant to be fixed.)
function entropy_state()
    buf = Ref{NTuple{4,UInt64}}((0x9e3779b97f4a7c15, 0xbf58476d1ce4e5b9, 0x94d049bb133111eb, 0x2545f4914f6cdd1d))
    ok = GC.@preserve buf @symbolcall getentropy(Ptr{UInt64}(pointer_from_objref(buf))::Ptr{UInt64}, UInt(32)::UInt)::Int32
    ok == 0 || error("could not get entropy from the system to seed the default random number generator: use `Random.seed!(seed)`")
    s0, s1, s2, s3 = buf[]
    return (s0, s1, s2, s3, s0 + 3s1 + 5s2 + 7s3)
end

@device_override @inline function Random.getstate(::TaskLocalRNG)
    s = TASKLOCAL_RNG_STATE[]
    if (s[1] | s[2] | s[3] | s[4]) == 0x0000000000000000
        s = entropy_state()
        TASKLOCAL_RNG_STATE[] = s
    end
    return s
end

@device_override @inline function Random.setstate!(x::TaskLocalRNG, (s0, s1, s2, s3, s4))
    old = TASKLOCAL_RNG_STATE[]
    # `nothing` leaves the splitmix state as it is
    TASKLOCAL_RNG_STATE[] = (s0, s1, s2, s3, s4 === nothing ? old[5] : s4)
    return x
end

# `Random.RandomDevice` (and with it `uuid4()`) reads the entropy of the system with `Libc.getrandom!`, which is libuv's `uv_random`. `getentropy` gives at most 256 bytes at a call.
@device_override function Libc.getrandom!(A::Union{Array,Base.RefValue})
    p = Ptr{UInt8}(pointer_from_objref(A))
    A isa Array && (p = Ptr{UInt8}(pointer(A)))
    n = sizeof(A)
    GC.@preserve A while n > 0
        m = min(n, 256)
        ok = @symbolcall getentropy(p::Ptr{UInt8}, UInt(m)::UInt)::Int32
        ok == 0 || error("could not get entropy from the system")
        p += m
        n -= m
    end
    return A
end

# `seed!(seed)` also records the seed in `task_local_storage()` (an `IdDict` on the current
# task), for `@testset` to restore. There are no tasks, so record it in a global.
const STATIC_TLS_SEED = Random.Xoshiro(0, 0, 0, 0, 0)
@device_override Random.get_tls_seed() = STATIC_TLS_SEED

# Bumper.jl looks up the current task to find its default buffer, and there are no tasks
@static if isdefined(StaticTools, :Bumper)
    @device_override StaticTools.Bumper.Internals.get_task() = 0
end
