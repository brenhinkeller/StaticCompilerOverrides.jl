# The file system, with the functions of libc: `stat` and what is made of it (`isfile`, `isdir`, `ispath`, `filesize`, `mtime`), `mkdir`, `rm`, `readdir`, `rename` (so `mv`),
# `cp`, `pwd`, `cd`, `homedir`, `tempdir`, `mktemp`, `mktempdir`, `tempname`, `realpath`, the process id, `errno`, and `ENV[name] = value`.
#
# Base does these with libuv (`uv_fs_*`), which needs the event loop. What is different: an error is a `SystemError` (with the message of `strerror`), where Base's is an
# `IOError` that has the code of libuv; a program that catches `IOError` for a missing file catches `SystemError` here (and `isfile` and `ispath` don't throw for one that is missing, as in Base).
# Not here: `symlink`, `chmod`, `touch`, `Mmap`, and the others that Base has.

# `errno`, as libc has it (a function that gives where it is: its name is not the same on the systems)
@static if Sys.isapple()
    @inline errno_pointer() = ccall(:__error, Ptr{Cint}, ())
else
    @inline errno_pointer() = ccall(:__errno_location, Ptr{Cint}, ())
end
@device_override Base.Libc.errno() = unsafe_load(errno_pointer())
@device_override Base.Libc.errno(e::Integer) = (unsafe_store!(errno_pointer(), Cint(e)); nothing)
@device_override Base.Libc.getpid() = ccall(:getpid, Int32, ())
@device_override Base.Libc.strerror(e::Integer) = unsafe_string(ccall(:strerror, Cstring, (Cint,), e))
@device_override Base.Libc.strerror() = unsafe_string(ccall(:strerror, Cstring, (Cint,), unsafe_load(errno_pointer())))

fs_error(what::AbstractString, path::AbstractString, code::Integer = unsafe_load(errno_pointer())) = throw(SystemError(string(what, "(", repr(path), ")"), Int(code)))

## stat

# `struct stat` of the C library of each system: where the fields are (macOS has the layout with 64-bit inodes, and its `stat` of x86 is `stat$INODE64`)
@static if Sys.isapple() && Sys.ARCH === :x86_64
    @eval stat_call(path, buf) = ccall($(QuoteNode(Symbol("stat\$INODE64"))), Cint, (Cstring, Ptr{UInt8}), path, buf)
    @eval lstat_call(path, buf) = ccall($(QuoteNode(Symbol("lstat\$INODE64"))), Cint, (Cstring, Ptr{UInt8}), path, buf)
else
    stat_call(path, buf) = ccall(:stat, Cint, (Cstring, Ptr{UInt8}), path, buf)
    lstat_call(path, buf) = ccall(:lstat, Cint, (Cstring, Ptr{UInt8}), path, buf)
end

@inline load_at(::Type{T}, buf::Vector{UInt8}, offset::Int) where {T} = GC.@preserve buf unsafe_load(Ptr{T}(pointer(buf) + offset))
@inline time_at(buf::Vector{UInt8}, offset::Int) = Float64(load_at(Int64, buf, offset)) + 1e-9 * Float64(load_at(Int64, buf, offset + 8))

function stat_struct(path::AbstractString, call)
    path = String(path)
    buf = zeros(UInt8, 256)
    r = GC.@preserve buf call(path, pointer(buf))
    if r != 0
        # (the code is the one of libuv, which is the negative of the number of the system)
        return Base.Filesystem.StatStruct(path, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.0, 0.0, Int32(-unsafe_load(errno_pointer())))
    end
    @static if Sys.isapple()
        return Base.Filesystem.StatStruct(path, UInt(load_at(Int32, buf, 0) % UInt32), UInt(load_at(UInt64, buf, 8)), UInt(load_at(UInt16, buf, 4)), Int(load_at(UInt16, buf, 6)),
            UInt(load_at(UInt32, buf, 16)), UInt(load_at(UInt32, buf, 20)), UInt(load_at(Int32, buf, 24) % UInt32), load_at(Int64, buf, 96), Int64(load_at(Int32, buf, 112)),
            load_at(Int64, buf, 104), time_at(buf, 48), time_at(buf, 64), Int32(0))
    elseif Sys.ARCH === :aarch64
        return Base.Filesystem.StatStruct(path, UInt(load_at(UInt64, buf, 0)), UInt(load_at(UInt64, buf, 8)), UInt(load_at(UInt32, buf, 16)), Int(load_at(UInt32, buf, 20)),
            UInt(load_at(UInt32, buf, 24)), UInt(load_at(UInt32, buf, 28)), UInt(load_at(UInt64, buf, 32)), load_at(Int64, buf, 48), Int64(load_at(Int32, buf, 56)),
            load_at(Int64, buf, 64), time_at(buf, 88), time_at(buf, 104), Int32(0))
    else # (x86_64 Linux)
        return Base.Filesystem.StatStruct(path, UInt(load_at(UInt64, buf, 0)), UInt(load_at(UInt64, buf, 8)), UInt(load_at(UInt32, buf, 24)), Int(load_at(UInt64, buf, 16)),
            UInt(load_at(UInt32, buf, 28)), UInt(load_at(UInt32, buf, 32)), UInt(load_at(UInt64, buf, 40)), load_at(Int64, buf, 48), load_at(Int64, buf, 56),
            load_at(Int64, buf, 64), time_at(buf, 88), time_at(buf, 104), Int32(0))
    end
end

# (an error other than that the file is not there, or not a directory, or not allowed, is an error, as in Base's `checkstat`)
function stat_checked(st)
    code = -Int(st.ioerrno)
    (code == 0 || code == 2 || code == 20 || code == 13 || code == 22 || code == 40) && return st # ENOENT, ENOTDIR, EACCES, EINVAL, ELOOP
    fs_error("stat", st.desc, code)
end
@device_override Base.Filesystem.stat(path::AbstractString) = stat_checked(stat_struct(path, stat_call))
@device_override Base.Filesystem.lstat(path::AbstractString) = stat_checked(stat_struct(path, lstat_call))
@device_override Base.ispath(path::String) = ccall(:access, Cint, (Cstring, Cint), path, 0) == 0

## directories and files

@device_override function Base.mkdir(path::AbstractString; mode::Integer = 0o777)
    path = String(path)
    ccall(:mkdir, Cint, (Cstring, UInt16), path, UInt16(mode)) == 0 || fs_error("mkdir", path)
    return path
end

# the names in a directory, sorted (not "." and ".."): `d_name` is at 21 on macOS, and at 19 on Linux
@static if Sys.isapple()
    const DIRENT_NAME_OFFSET = 21
else
    const DIRENT_NAME_OFFSET = 19
end
@device_override function Base.readdir(dir::AbstractString; join::Bool = false, sort::Bool = true)
    dir = String(dir)
    handle = ccall(:opendir, Ptr{Cvoid}, (Cstring,), dir)
    handle == C_NULL && fs_error("readdir", dir)
    entries = String[]
    while true
        entry = ccall(:readdir, Ptr{UInt8}, (Ptr{Cvoid},), handle)
        entry == C_NULL && break
        name = unsafe_string(entry + DIRENT_NAME_OFFSET)
        (name == "." || name == "..") && continue
        push!(entries, join ? joinpath(dir, name) : name)
    end
    ccall(:closedir, Cint, (Ptr{Cvoid},), handle)
    sort && sort!(entries)
    return entries
end
@device_override Base.readdir(; join::Bool = false, sort::Bool = true) = readdir(pwd(); join, sort)

@device_override function Base.rm(path::AbstractString; force::Bool = false, recursive::Bool = false, allow_delayed_delete::Bool = true)
    path = String(path)
    st = lstat(path)
    if !ispath(st)
        force && return nothing
        fs_error("unlink", path, 2)
    end
    if islink(st) || !isdir(st)
        ccall(:unlink, Cint, (Cstring,), path) == 0 || (force && unsafe_load(errno_pointer()) == 2) || fs_error("unlink", path)
    else
        if recursive
            for name in readdir(path)
                rm(joinpath(path, name); force, recursive = true)
            end
        end
        ccall(:rmdir, Cint, (Cstring,), path) == 0 || (force && unsafe_load(errno_pointer()) == 2) || fs_error("rmdir", path)
    end
    return nothing
end

@device_override function Base.rename(oldpath::AbstractString, newpath::AbstractString)
    oldpath, newpath = String(oldpath), String(newpath)
    ccall(:rename, Cint, (Cstring, Cstring), oldpath, newpath) == 0 || fs_error("rename", oldpath)
    return newpath
end

# a copy of a file (what it has, and the mode), or of a directory with what is in it
function copy_tree(src::String, dst::String, force::Bool)
    if isdir(src)
        ispath(dst) ? (force ? rm(dst; recursive = true) : throw(ArgumentError(string("'", dst, "' exists. `force=true` is required to remove '", dst, "' before copying.")))) : nothing
        mkdir(dst)
        for name in readdir(src)
            copy_tree(joinpath(src, name), joinpath(dst, name), force)
        end
    else
        if ispath(dst)
            force || throw(ArgumentError(string("'", dst, "' exists. `force=true` is required to remove '", dst, "' before copying.")))
            rm(dst; recursive = true)
        end
        input = open(src)
        bytes = read(input)
        close(input)
        output = open(dst, "w")
        write(output, bytes)
        close(output)
    end
    return dst
end
@device_override Base.cp(src::AbstractString, dst::AbstractString; force::Bool = false, follow_symlinks::Bool = false) = copy_tree(String(src), String(dst), force)

# `mv`: a `rename`, and a copy and removal where that can't be done (another device)
@device_override function Base.mv(src::AbstractString, dst::AbstractString; force::Bool = false)
    src, dst = String(src), String(dst)
    if ispath(dst) && !force
        throw(ArgumentError(string("'", dst, "' exists. `force=true` is required to remove '", dst, "' before moving.")))
    end
    if ccall(:rename, Cint, (Cstring, Cstring), src, dst) != 0
        code = unsafe_load(errno_pointer())
        if code == 18 # EXDEV: not the same device
            copy_tree(src, dst, true)
            rm(src; recursive = true)
        elseif force && ispath(dst) && code != 2
            rm(dst; recursive = true)
            ccall(:rename, Cint, (Cstring, Cstring), src, dst) == 0 || fs_error("rename", src)
        else
            fs_error("rename", src, code)
        end
    end
    return dst
end

@device_override function Base.pwd()
    buffer = zeros(UInt8, 4096)
    p = GC.@preserve buffer ccall(:getcwd, Ptr{UInt8}, (Ptr{UInt8}, Csize_t), pointer(buffer), 4096)
    p == C_NULL && fs_error("pwd", "")
    return GC.@preserve buffer unsafe_string(pointer(buffer))
end
@device_override function Base.cd(dir::AbstractString)
    dir = String(dir)
    ccall(:chdir, Cint, (Cstring,), dir) == 0 || fs_error("cd", dir)
    return nothing
end
@device_override Base.cd() = cd(homedir())

@device_override function Base.realpath(path::AbstractString)
    path = String(path)
    p = ccall(:realpath, Ptr{UInt8}, (Cstring, Ptr{UInt8}), path, C_NULL)
    p == C_NULL && fs_error("realpath", path)
    s = unsafe_string(p)
    ccall(:free, Cvoid, (Ptr{UInt8},), p)
    return s
end

## where things are, and temporary files

@device_override Base.homedir() = (h = get(ENV, "HOME", ""); isempty(h) ? "/" : h)
@device_override Base.tempdir() = (t = get(ENV, "TMPDIR", ""); isempty(t) ? "/tmp" : (endswith(t, "/") && length(t) > 1 ? t[1:end-1] : t))

# (a name that does not exist, made as `mkstemp` makes one)
@device_override function Base.tempname(parent::AbstractString = tempdir(); max_tries::Int = 100, cleanup::Bool = true)
    template = string(joinpath(String(parent), "jl_"), "XXXXXX")
    fd = GC.@preserve template ccall(:mkstemp, Cint, (Ptr{UInt8},), pointer(template))
    fd < 0 && fs_error("tempname", template)
    ccall(:close, Cint, (Cint,), fd)
    ccall(:unlink, Cint, (Cstring,), template)
    return template
end
@device_override function Base.mktemp(parent::AbstractString = tempdir(); cleanup::Bool = true)
    template = Vector{UInt8}(string(joinpath(String(parent), "jl_"), "XXXXXX\0"))
    fd = GC.@preserve template ccall(:mkstemp, Cint, (Ptr{UInt8},), pointer(template))
    fd < 0 && fs_error("mktemp", String(copy(template)))
    path = String(template[1:end-1])
    fp = ccall(:fdopen, Ptr{Cvoid}, (Cint, Cstring), fd, "r+")
    return path, StaticFile(fp)
end
@device_override function Base.mktemp(f::Function, parent::AbstractString = tempdir(); cleanup::Bool = true)
    path, io = mktemp(parent)
    try
        return f(path, io)
    finally
        close(io)
        rm(path; force = true)
    end
end
@device_override function Base.mktempdir(parent::AbstractString = tempdir(); prefix::AbstractString = "jl_", cleanup::Bool = true)
    template = Vector{UInt8}(string(joinpath(String(parent), String(prefix)), "XXXXXX\0"))
    p = GC.@preserve template ccall(:mkdtemp, Ptr{UInt8}, (Ptr{UInt8},), pointer(template))
    p == C_NULL && fs_error("mktempdir", String(copy(template)))
    return String(template[1:end-1])
end
@device_override function Base.mktempdir(f::Function, parent::AbstractString = tempdir(); prefix::AbstractString = "jl_", cleanup::Bool = true)
    path = mktempdir(parent; prefix)
    try
        return f(path)
    finally
        rm(path; force = true, recursive = true)
    end
end

## the environment

@device_override function Base.setindex!(::Base.EnvDict, value, name::AbstractString)
    name, value = String(name), String(value)
    ccall(:setenv, Cint, (Cstring, Cstring, Cint), name, value, 1) == 0 || fs_error("setenv", name)
    return value
end
@device_override function Base.delete!(::Base.EnvDict, name::AbstractString)
    ccall(:unsetenv, Cint, (Cstring,), String(name))
    return nothing
end

## `memrchr` is not in the C library of macOS (Julia's own is in libjulia)

function memrchr_loop(a, b, i::Int)
    fst = firstindex(a)
    j = i
    while j >= fst
        @inbounds a[j] == b && return j
        j -= 1
    end
    return nothing
end
@device_override Base.memrchr(a::Base.DenseUInt8, b::UInt8, i::Int) = memrchr_loop(a, b, i)
@device_override Base.memrchr(a::Base.DenseInt8, b::Int8, i::Int) = memrchr_loop(a, b, i)

## `Threads.@threads`: the program has one thread, so the loop runs on it, in order (a loop that has no race gives what it gives with more)

@device_override Base.Threads.threading_run(fun, static) = (fun(1); nothing)
@device_override Base.Threads.threadpoolsize(pool::Symbol = :default) = 1
