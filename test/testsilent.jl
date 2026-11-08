# Cases found by a review for silently wrong results: what a program must not do quietly, and what it has to say instead.

# Objects that are constants are copied into the binary, and have other addresses there. A table that was made with the
# addresses of its keys (`hash` of a mutable struct is its `objectid`, which is the address) would not find them.
mutable struct AddrKey; x::Int; end
struct AddrWrap; v::Vector{Int}; end                      # an immutable that refers to a mutable object: hashed by that object's address
mutable struct HashedKey; x::Int; end
Base.hash(k::HashedKey, h::UInt) = hash(k.x, h)           # its own hash: no address in it
Base.:(==)(a::HashedKey, b::HashedKey) = a.x == b.x

const ADDR_KEYS = [AddrKey(1), AddrKey(2)]
const ADDR_DICT = Dict(k => k.x for k in ADDR_KEYS)
const ADDR_SET = Set(ADDR_KEYS)
const ADDR_IDDICT = IdDict(k => k.x for k in ADDR_KEYS)
const WRAPS = [AddrWrap([1]), AddrWrap([2])]
const WRAP_DICT = Dict(w => 1 for w in WRAPS)
const HASHED_DICT = Dict(HashedKey(1) => 10, HashedKey(2) => 20)
const STRING_DICT = Dict("a" => 1, "b" => 2)
const EMPTY_IDDICT = IdDict{AddrKey,Int}()

addr_haskey() = haskey(ADDR_DICT, ADDR_KEYS[1])
addr_get() = get(ADDR_DICT, ADDR_KEYS[2], -1)
addr_in_set() = ADDR_KEYS[1] in ADDR_SET
addr_iddict() = get(ADDR_IDDICT, ADDR_KEYS[2], -1)
addr_wrapped() = get(WRAP_DICT, WRAPS[1], -1)
hashed_get() = get(HASHED_DICT, HashedKey(2), -1)
string_get() = STRING_DICT["b"]
empty_iddict() = (d = EMPTY_IDDICT; d[AddrKey(1)] = 5; length(d))
runtime_dict() = (d = Dict{AddrKey,Int}(); k = AddrKey(1); d[k] = 3; get(d, k, -1))

@testset "Constant tables hashed by address" begin
    for f in (addr_haskey, addr_get, addr_in_set, addr_iddict, addr_wrapped)
        status, detail = static_status(f)
        @testset "$(nameof(f))" begin
            @test status == :compile_error # (it is refused, and says why)
            @test occursin("address", string(detail))
        end
    end
    for f in (hashed_get, string_get, empty_iddict, runtime_dict)
        @testset "$(nameof(f))" begin
            @test static_status(f)[1] == :ok
        end
    end
end

# `deepcopy` of a struct is made field by field here, so a method of `deepcopy_internal` that a package defines for its type is not used
struct CustomCopy; v::Vector{Int}; end
Base.deepcopy_internal(x::CustomCopy, d::IdDict) = (haskey(d, x) ? d[x] : (d[x] = CustomCopy(Int[])))
struct PlainCopy; v::Vector{Int}; end
custom_deepcopy() = length(deepcopy(CustomCopy([1, 2, 3])).v)
plain_deepcopy() = length(deepcopy(PlainCopy([1, 2, 3])).v)
nested_custom_deepcopy() = length(deepcopy([CustomCopy([1, 2, 3])])[1].v)

@testset "deepcopy with a method of the package" begin
    for f in (custom_deepcopy, nested_custom_deepcopy)
        # (compiling says so, once for each type)
        status, detail = f === custom_deepcopy ? (@test_logs (:warn, r"deepcopy_internal") match_mode = :any static_status(f)) : static_status(f)
        @testset "$(nameof(f))" begin
            @test status in (:compile_error, :runtime_error) # (not the wrong answer)
        end
    end
    @test static_status(plain_deepcopy)[1] == :ok
end

# Errors of libc that were ignored: a file that can't be written (a full disk) was closed without a word
@static if Sys.islinux()
    full_disk() = (io = open("/dev/full", "w"); write(io, "data"); close(io); 1)
    full_disk_flush() = (io = open("/dev/full", "w"); write(io, "data"); flush(io); close(io); 1)
    @testset "Write errors" begin
        @test static_status(full_disk)[1] == :runtime_error
        @test static_status(full_disk_flush)[1] == :runtime_error
    end
end

# `@simd` reductions are reassociated by Julia (several partial sums, with the vectorizer): without it they are a plain loop, and the results
# differ in the last digits (and are less accurate: `sum(fill(0.1f0, 1000))` is 99.99905 for a plain loop, and 99.99994 for Julia)
simd_sum32() = (s = 0f0; v = fill(0.1f0, 1000); @simd for x in v; s += x; end; s)
simd_sum64() = (s = 0.0; v = fill(0.1, 1000); @simd for x in v; s += x; end; s)
base_sum32() = sum(fill(0.1f0, 1000))
base_sum64() = sum(fill(0.1, 1000))
base_dot() = (x = fill(0.1f0, 999); y = fill(0.3f0, 999); LinearAlgebra.dot(x, y))
base_mean() = (using_Statistics_mean(fill(0.1f0, 1000)))
using_Statistics_mean(v) = sum(v) / length(v)
@testset "@simd reductions" for f in (simd_sum32, simd_sum64, base_sum32, base_sum64, base_dot, base_mean)
    @test static_status(f)[1] == :ok
end

# Memory safety. The size of a string or of the memory of an array has the header added to it, which wraps around for a size that is negative
# (as a number of bytes, one that is far too large): the object was then a few bytes, and what was written in it was not.
function exit_status_and_output(f)
    main = StaticCompilerOverrides.make_main(f)
    exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)))
    out = IOBuffer()
    proc = run(pipeline(ignorestatus(`$exe`); stdout = out, stderr = out))
    return proc.exitcode, String(take!(out))
end
huge_string() = (s = Base._string_n(Base.inferencebarrier(-1)::Int); ncodeunits(s))
huge_memory() = (m = Memory{UInt8}(undef, Base.inferencebarrier(typemax(Int) >> 1)::Int); m[1] = 0x01; Int(m[1]))
@testset "Allocation sizes that are too large" begin
    for f in (huge_string, huge_memory)
        @testset "$(nameof(f))" begin
            code, out = exit_status_and_output(f)
            @test code != 0 # (the program stops: with a message of its own, or an uncaught exception)
            @test !isempty(out)
        end
    end
end

# On Linux the collector decides whether it is on the stack of the main thread by how far the stack pointer is from the base of the stack: the
# limit of the size of the stack is the far end (`getrlimit`), which it reads
rlimit_stack() = Int(StaticCompilerOverrides.Runtime.Heap.rlimit_stack_size())
@testset "Size limit of the stack" begin
    @test 1 << 16 <= rlimit_stack() <= 1 << 40
    @test static_status(rlimit_stack)[1] == :ok
end

# A file that was closed has no `FILE*`: reading it was a call of libc with a null pointer
closed_read() = (path = "/tmp/static_overrides_closed_test.txt"; write(path, "abc"); io = open(path); close(io); try; read(io, UInt8); 0; catch; 1; end)
@testset "Closed files" begin
    @test static_status(closed_read)[1] == :ok
end
