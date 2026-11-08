# Input and output without libuv.
#
# Julia's `stdout`, `stderr` and `stdin` are libuv streams, which need the Julia runtime. Here
# they are streams of libc (`FILE*`), as an `IO` that implements the interface that Base's
# `print`, `show`, `readline`, and so on are written against, so that all of Base's own code
# for writing and reading things works on it unchanged.

using StaticTools: FILE, stdinp, stdoutp, stderrp, fwrite, fread!, getc
import StaticTools: printf # (to add a method)

"""
    StaticIO{S}

An `IO` for one of the standard streams of libc, `S` being `:stdin`, `:stdout` or `:stderr`.
There is no buffering besides that of libc (which flushes the streams when the program exits).

These are the streams to use in compiled code instead of `stdin`, `stdout` and `stderr` of Base,
which are globals of the abstract type `IO`, so that calls using them can't be resolved when
compiling: [`STDIN`](@ref), [`STDOUT`](@ref) and [`STDERR`](@ref). `print(x)`, `println(x)` and
`show(x)`, which write to `stdout`, do use [`STDOUT`](@ref).
"""
struct StaticIO{S} <: IO end

"The standard input of libc, an [`StaticIO`](@ref); use instead of `stdin`."
const STDIN = StaticIO{:stdin}()
"The standard output of libc, an [`StaticIO`](@ref); use instead of `stdout`."
const STDOUT = StaticIO{:stdout}()
"The standard error of libc, an [`StaticIO`](@ref); use instead of `stderr`."
const STDERR = StaticIO{:stderr}()

"""
    StaticFile

A file opened with `open` (see `files.jl`). Like the standard streams, it is a `FILE*` of libc, so the
methods that read and write are the same for the two.
"""
mutable struct StaticFile <: IO
    fp::Ptr{FILE}
end

"The streams of libc: [`StaticIO`](@ref) and [`StaticFile`](@ref)"
const LibcStream = Union{StaticIO, StaticFile}

# the libc `FILE*` of the stream
filepointer(f::StaticFile) = f.fp
filepointer(::StaticIO{:stdin}) = stdinp()
filepointer(::StaticIO{:stdout}) = stdoutp()
filepointer(::StaticIO{:stderr}) = stderrp()

Base.isopen(::StaticIO) = true
Base.close(::StaticIO) = nothing # the standard streams are not ours to close
Base.isreadable(::StaticIO{S}) where {S} = S === :stdin
Base.iswritable(::StaticIO{S}) where {S} = S !== :stdin

## writing

# (a write or a flush that libc reports as failed is an error, as it is in Julia: a full disk, a closed pipe. Without this, what could not be written is lost
# without a word.)
write_error() = throw(ErrorException("error writing to a stream (the write or flush of libc failed)"))

function Base.unsafe_write(io::LibcStream, p::Ptr{UInt8}, n::UInt)
    written = Int(fwrite(filepointer(io), p, 1, Int64(n)))
    written == Int(n) || write_error()
    return written
end

function Base.write(io::LibcStream, x::UInt8)
    status = @symbolcall fputc(Int32(x)::Int32, filepointer(io)::Ptr{FILE})::Int32
    status < 0 && write_error()
    return 1
end

function Base.flush(io::LibcStream)
    status = @symbolcall fflush(filepointer(io)::Ptr{FILE})::Int32
    status == 0 || write_error()
    return nothing
end

## reading

function Base.read(io::LibcStream, ::Type{UInt8})
    c = getc(filepointer(io))
    c < 0 && throw(EOFError())
    return UInt8(c)
end

function Base.eof(io::LibcStream)
    fp = filepointer(io)
    c = getc(fp)
    c < 0 && return true
    @symbolcall ungetc(c::Int32, fp::Ptr{FILE})::Int32
    return false
end

# the next byte, without reading it: libc can put back a character (the generic one uses `mark` and `reset`)
function Base.peek(io::LibcStream, ::Type{UInt8})
    fp = filepointer(io)
    c = getc(fp)
    c < 0 && throw(EOFError())
    @symbolcall ungetc(c::Int32, fp::Ptr{FILE})::Int32
    return UInt8(c)
end

function Base.unsafe_read(io::LibcStream, p::Ptr{UInt8}, n::UInt)
    got = fread!(p, filepointer(io), 1, Int64(n))
    got == Int64(n) || throw(EOFError())
    return nothing
end

## `printf` of StaticTools, to a stream (`printf(fmt, args...)` writes to the standard output, which is
## the same stream as `STDOUT`: both use the buffer of libc, so what they write is in order)

printf(io::LibcStream, fmt, args...) = printf(filepointer(io), fmt, args...)

## `print`, `println` and `show` without an `IO` write to the standard output. In Base they use
## `stdout`, which is not usable (see above).
##
## An overlay method that covers a call entirely is used *instead of* all the methods of Base,
## also the more specific ones. So these cannot just replace the methods of Base that have
## `stdout` in them, like `print(x1, x2) = print(stdout, x1, x2)`: that would also be used for
## `print(io, x)`, and not use the methods of Base for printing a `String`, a `Char`, ...
## The methods below are written so that they either do what Base does for the calls that have
## an `IO` for the first argument (when that is easy to do exactly), or don't cover them.

# the first argument of calls that have no `IO`, and no output stream: calls with these are
# `print(x1, x2)`, written to the standard output
const Printable = Union{AbstractString, Number, AbstractChar, Symbol, Nothing, Missing, Tuple,
                        AbstractArray, AbstractDict, AbstractSet, Pair, Type, Function, Enum, Ref}

# `print(io, xs...)` of Base, with the loop over the arguments (of different types) unrolled, see
# `print_to_string` in `base.jl`; more arguments than one: Base's other methods are for one
@device_override function Base.print(io::IO, x1, x2, xs...)
    lock(io)
    print_each(io, x1, x2, xs...)
    unlock(io)
    return nothing
end

# print(x) and print(x1, x2): Base has no other methods with these numbers of arguments that
# are not for an `IO` first, but for `print(x1, x2)` those are many, so only for what is not an `IO`
@device_override Base.print(x) = print(STDOUT, x)
@device_override Base.print(x1::Printable, x2) = print(STDOUT, x1, x2)
@device_override Base.print(x1, x2, x3, xs...) = print_implicit(x1, x2, x3, xs...)
print_implicit(io::IO, xs...) = print(io, xs...)
print_implicit(x, xs...) = print(STDOUT, x, xs...)

# println: Base's `println(io::IO, xs...) = print(io, xs..., "\n")` for an `IO` first
@device_override Base.println() = print(STDOUT, "\n")
@device_override Base.println(x) = println_implicit(x)
@device_override Base.println(x1, x2) = println_implicit(x1, x2)
@device_override Base.println(x1, x2, x3, xs...) = println_implicit(x1, x2, x3, xs...)
println_implicit(io::IO) = print(io, "\n")
println_implicit(io::IO, xs...) = print(io, xs..., "\n")
println_implicit(x) = print(STDOUT, x, "\n")
println_implicit(x, xs...) = print(STDOUT, x, xs..., "\n")

@device_override Base.show(x) = show(STDOUT, x)
