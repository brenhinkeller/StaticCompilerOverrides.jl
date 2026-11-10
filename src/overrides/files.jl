# Files, with `fopen`, `fread!`, `fwrite`, ... of libc (from StaticTools).
#
# `open` gives a [`StaticFile`](@ref) (defined in `io.jl`), an `IO` like the standard streams, so what
# Base has for reading and writing an `IO` works with it: `read(io, String)`, `readline`, `readlines`,
# `eachline`, `println(io, x)`, `write`, `@printf(io, ...)`, `open(f, path, mode)`, `read(path, String)`,
# `write(path, x)`, ...

using StaticTools: fopen, fclose, ftell, fseek, frewind, SEEK_SET, SEEK_CUR, SEEK_END

# A `String` is terminated by a NUL, as C wants it, and a `SubString` is not
function open_file(path::AbstractString, mode::AbstractString)
    path, mode = String(path), String(mode)
    fp = GC.@preserve path mode fopen(pointer(path), pointer(mode))
    fp == C_NULL && throw(ErrorException(string("could not open file ", path)))
    return StaticFile(fp)
end

"""
    open(path, [mode = "r"]) -> StaticFile

Open the file `path` with `fopen` of libc: `mode` is a C `fopen` mode (`"r"`, `"w"`, `"a"`, `"r+"`, ...).
Close it with `close`; `open(f, path, mode)` does, after calling `f(io)`. (The keyword arguments of
`open` in Base, like `read = true`, are not supported.)
"""
@device_override Base.open(path::AbstractString, mode::AbstractString) = open_file(path, mode)
@device_override Base.open(path::AbstractString) = open_file(path, "r")

function Base.close(f::StaticFile)
    fp = f.fp
    f.fp = C_NULL
    # (`fclose` writes what is buffered, and reports if that failed: the file is closed either way)
    fp == C_NULL || fclose(fp) == 0 || write_error()
    return nothing
end

Base.isopen(f::StaticFile) = f.fp != C_NULL
Base.isreadable(f::StaticFile) = isopen(f)
Base.iswritable(f::StaticFile) = isopen(f)

## position

Base.position(f::StaticFile) = Int(ftell(filepointer(f)))
Base.seek(f::StaticFile, n::Integer) = (fseek(filepointer(f), Int64(n), SEEK_SET); f)
Base.seekstart(f::StaticFile) = (fseek(filepointer(f), Int64(0), SEEK_SET); f)
Base.seekend(f::StaticFile) = (fseek(filepointer(f), Int64(0), SEEK_END); f)
Base.skip(f::StaticFile, n::Integer) = (fseek(filepointer(f), Int64(n), SEEK_CUR); f)

function Base.filesize(f::StaticFile)
    fp = filepointer(f)
    here = ftell(fp)
    fseek(fp, Int64(0), SEEK_END)
    size = ftell(fp)
    fseek(fp, here, SEEK_SET)
    return Int(size)
end

# what is left to read, which lets `read(io)` allocate once
Base.bytesavailable(f::StaticFile) = filesize(f) - position(f)

## Writing and reading with `write`, `readline`, `readlines` and `eachline`
##
## Those of Base, for a file name or without a stream, which has the stream from `stdin` (the global
## of the abstract type `IO`), are written with keyword arguments (`keep`, `cancel`), and in terms of
## closures (`eachline` stores the function that closes the file in a field of the abstract type `Function`),
## which can't be resolved when compiling. These do the same for calls without those keyword arguments:
## (`keep = true` is not supported.)

# `write(io, xs...)` loops over its arguments, which have different types (as `print`, see `base.jl`)
write_all(io) = 0
write_all(io, x, rest...) = write(io, x) + write_all(io, rest...)

@device_override Base.write(io::IO, x1, x2, xs...) = write_all(io, x1, x2, xs...)
@device_override function Base.write(path::AbstractString, x, xs...)
    io = open_file(path, "w")
    n = write_all(io, x, xs...)
    close(io)
    return n
end

function readlines_of(io::IO)
    lines = String[]
    while !eof(io)
        push!(lines, readline(io))
    end
    return lines
end

@device_override Base.readlines(io::IO) = readlines_of(io)
@device_override Base.readlines() = readlines_of(STDIN)
@device_override function Base.readlines(path::AbstractString)
    io = open_file(path, "r")
    lines = readlines_of(io)
    close(io)
    return lines
end

@device_override Base.readline() = readline(STDIN)
@device_override function Base.readline(path::AbstractString)
    io = open_file(path, "r")
    line = readline(io)
    close(io)
    return line
end

"""
    StaticEachLine

What `eachline` is in compiled code: an iterator of the lines of a stream (which is closed at the end if
it is of a file that `eachline` opened).
"""
struct StaticEachLine{IOT<:IO}
    stream::IOT
    owned::Bool
end

function Base.iterate(itr::StaticEachLine, state = nothing)
    if eof(itr.stream)
        itr.owned && close(itr.stream)
        return nothing
    end
    return readline(itr.stream), nothing
end
Base.eltype(::Type{<:StaticEachLine}) = String
Base.IteratorSize(::Type{<:StaticEachLine}) = Base.SizeUnknown()

@device_override Base.eachline() = StaticEachLine(STDIN, false)
@device_override Base.eachline(io::IO) = StaticEachLine(io, false)
@device_override Base.eachline(path::AbstractString) = StaticEachLine(open_file(path, "r"), true)

# The size of a file, by opening it (Base uses `stat`, which is not available)
@device_override function Base.filesize(path::AbstractString)
    io = open_file(path, "r")
    size = filesize(io)
    close(io)
    return size
end
