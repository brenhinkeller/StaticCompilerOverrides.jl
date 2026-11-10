# Memory-mapped files, with the functions of libc.
#
# `Mmap.mmap(path, ...)` opens the file with libuv, takes the size of it with `fstat`, and registers a finalizer that unmaps the memory. What is here is the same for the arrays of a
# file that is named by its path (the other ways to map, from an open stream or an anonymous mapping, are not here): a file that is there is mapped to be read (`mmap` opens it with `"r"`),
# and one that is not is created, as `"w+"` does, and made as long as the array needs. The memory is not unmapped before the program ends (the array is not owned by anything that could do it).
module StaticCompilerOverridesMmapExt

using StaticCompilerOverrides: @device_override
using Mmap: Mmap

# the flags of `open` of each system (`O_RDONLY` is 0, `O_RDWR` is 2)
@static if Sys.isapple()
    const O_CREAT = Cint(0x200)
    const O_TRUNC = Cint(0x400)
else
    const O_CREAT = Cint(0x40)
    const O_TRUNC = Cint(0x200)
end
const SEEK_END = Cint(2)

mmap_error(what::AbstractString, path::AbstractString) = throw(SystemError(string(what, "(", repr(path), ")"), Int(Base.Libc.errno())))

function mmap_file(path::String, ::Type{Array{T,N}}, dims::NTuple{N,Integer}, offset::Integer, grow::Bool, shared::Bool) where {T,N}
    isbitstype(T) || throw(ArgumentError("unable to mmap $T; must satisfy isbitstype(T) == true"))
    len = Mmap.checked_bytesize(dims, Base.aligned_sizeof(T))
    len >= 0 || throw(ArgumentError("requested size must be ≥ 0, got $len"))
    len == 0 && return Array{T}(undef, dims)
    offset >= 0 || throw(ArgumentError("requested offset must be ≥ 0, got $offset"))
    exists = isfile(path)
    fd = exists ? ccall(:open, Cint, (Cstring, Cint), path, Cint(0)) :
                  ccall(:open, Cint, (Cstring, Cint, Base.Cmode_t...), path, Cint(2) | O_CREAT | O_TRUNC, Base.Cmode_t(0o666))
    fd < 0 && mmap_error("open", path)
    wanted = Int(offset) + len
    if exists
        size = ccall(:lseek, Int64, (Cint, Int64, Cint), fd, 0, SEEK_END)
        if wanted > size
            ccall(:close, Cint, (Cint,), fd)
            throw(ArgumentError("requested size $wanted larger than file size $size, but the file is read-only"))
        end
    else
        if !grow
            ccall(:close, Cint, (Cint,), fd)
            throw(ArgumentError("requested size $wanted is larger than the file, which is new, and cannot grow"))
        end
        ccall(:ftruncate, Cint, (Cint, Int64), fd, wanted) == 0 || (ccall(:close, Cint, (Cint,), fd); mmap_error("ftruncate", path))
    end
    pagesize = Int(ccall(:getpagesize, Cint, ()))
    page_offset = Int(offset) - Int(offset) % pagesize
    skip = Int(offset) - page_offset
    prot = (!exists || !shared) ? Mmap.PROT_READ | Mmap.PROT_WRITE : Mmap.PROT_READ
    flags = shared ? Mmap.MAP_SHARED : Mmap.MAP_PRIVATE
    ptr = ccall(:mmap, Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t, Cint, Cint, Cint, Int64), C_NULL, Csize_t(len + skip), prot, flags, fd, page_offset)
    failed = reinterpret(UInt, ptr) == typemax(UInt)
    failed && (ccall(:close, Cint, (Cint,), fd); mmap_error("mmap", path))
    ccall(:close, Cint, (Cint,), fd)
    return unsafe_wrap(Array, Ptr{T}(ptr + skip), dims)
end

@device_override function Mmap.mmap(file::AbstractString, ::Type{Array{T,N}}, dims::NTuple{N,Integer}, offset::Integer = 0; grow::Bool = true, shared::Bool = true) where {T,N}
    return mmap_file(String(file), Array{T,N}, dims, offset, grow, shared)
end

@device_override function Mmap.mmap(file::AbstractString, ::Type{Array{T,N}}, len::Integer, offset::Integer = 0; grow::Bool = true, shared::Bool = true) where {T,N}
    return mmap_file(String(file), Array{T,N}, (Int(len),), offset, grow, shared)
end

# (without a size: the file from the offset to its end, in elements of `T`)
@device_override function Mmap.mmap(file::AbstractString, ::Type{Vector{T}} = Vector{UInt8}; grow::Bool = true, shared::Bool = true) where {T}
    return mmap_file(String(file), Vector{T}, (div(Int(filesize(file)), Base.aligned_sizeof(T)),), 0, grow, shared)
end

end # module
