# The loader of the libraries that a program calls functions of: `static_library_symbol(i)` is the address of the function number `i`, which
# is found the first time that it is needed (`dlopen` of the library, and `dlsym`).
#
# This is written in Julia, over raw pointers, and compiled like the heap (see `heap.jl`): it must not allocate with the collector, throw or
# dispatch. What it knows is a table that the linker writes for the program (`define_library_table!` in `libraries.jl`), as words:
#
#     nlibs, nsymbols,
#     for each library: the path that it had when compiling (a C string), its file name (a C string, or 0), a list of the libraries that it needs as
#                       { count, number of each... } (or 0), and one word that is not used,
#     for each function: the number of its library, and its name (a C string)
#
# A library is opened after those that it needs: they are opened by their paths, so that the names that it has for them (`@rpath/libgmp.10.dylib`,
# `libgmp.so.10`) are those of libraries that are loaded, which the system finds before it looks for files. A library that has a file name is
# looked for next to the program first, in the folder `lib` of it (where `libraries = :bundle` puts them), and then at its path.

# TODO (come back to this): finalizers that are Julia functions (`finalizer(f, x)`) are not supported; only C functions are (`ijl_gc_add_ptr_finalizer`,
# which is what BigInt has: see `heap.jl`, `run_finalizers`). The blocker is that the collector is compiled apart, as Julia over raw pointers, and can't call
# Julia code: `f` is a closure whose type `F`, and the type `T` of `x`, are only known at the `finalizer(f, x)` call, and running it needs the code for that
# `(F, T)` and a pointer to it, which static compilation has no way to hand out (`@cfunction` needs the types when the macro is expanded, not in a generic overlay).
# Ways in:
#   1. A thunk for each call site: the overlay of `finalizer` is specialized on `F` and `T`, and `link_runtime!` finds the calls and takes the address of the
#      specialized function (an LLVM-level step; the open question is whether that address can be recovered), and registers `(thunk, closure, object)`.
#   2. A queue that the program drains: the collector keeps what is dead and has a finalizer alive (marks it), queues it, and typed Julia code runs the
#      finalizers at a safe point (after `GC.gc()`, or the slow path of allocation). That still needs the dispatch of 1 for each entry, but avoids running Julia
#      code inside a collection.
# Either way: the registry would have to keep the closure (what it captures) alive, so it is a root and not the weak table of addresses that C finalizers have;
# an object that a finalizer stores somewhere (resurrection) must live that cycle and be freed in the next; a finalizer may allocate (and so collect), which a
# queue avoids; and an exception from one is swallowed, as Julia does.
# Cheaper, for what is needed now: a C-callable shim for each case, as one that loads the `regex` field of a `Regex` and calls `pcre2_code_free_8` (so that a
# `Regex` made when the program runs is freed; today `finalizer(f, ::Regex)` is a no-op in `regex.jl`, and its compiled code stays until the program ends).

module Loader

using StaticTools: calloc, free, @symbolcall, @c_str

const RTLD_NOW = Int32(2)
const S_HANDLES, S_SYMBOLS, S_DIRECTORY = 1, 2, 3 # the handles of the libraries, the functions that were found, the folder of the program (a C string; 1 if not known)

@inline table() = Base.llvmcall(("""
    @_static_libs = external hidden global i64
    define i64 @table() alwaysinline {
      ret i64 ptrtoint (ptr @_static_libs to i64)
    }""", "table"), UInt, Tuple{})

@inline state() = Base.llvmcall(("""
    @_static_library_state = linkonce_odr hidden global [4 x i64] zeroinitializer, align 16
    define i64 @state() alwaysinline {
      ret i64 ptrtoint (ptr @_static_library_state to i64)
    }""", "state"), UInt, Tuple{})

@inline sget(i::Int) = unsafe_load(Ptr{UInt}(state()), i)
@inline sset(i::Int, v::UInt) = unsafe_store!(Ptr{UInt}(state()), v, i)
@inline ld(p::UInt, i::Int) = unsafe_load(Ptr{UInt}(p), i + 1)
@inline st(p::UInt, i::Int, v::UInt) = unsafe_store!(Ptr{UInt}(p), v, i + 1)
@inline byte(p::UInt, i::Int) = unsafe_load(Ptr{UInt8}(p), i + 1)

@inline function cstring_length(p::UInt)
    n = 0
    while byte(p, n) != 0x00
        n += 1
    end
    return n
end

@inline write_text(p::UInt) = @symbolcall write(Int32(2)::Int32, Ptr{UInt8}(p)::Ptr{UInt8}, cstring_length(p)::Int)::Int

# say what is wrong, on the standard error, and stop
@noinline function fail(what::UInt, path::UInt)
    head = c"Cannot use a library that the program calls functions of: "
    sep = c" "
    nl = c"\n"
    GC.@preserve head sep nl begin
        write_text(UInt(pointer(head)))
        write_text(what)
        write_text(UInt(pointer(sep)))
        write_text(path)
        write_text(UInt(pointer(nl)))
    end
    @symbolcall exit(Int32(1)::Int32)::Int32
    return
end

@noinline function out_of_memory()
    msg = c"Out of memory error"
    GC.@preserve msg @symbolcall puts(pointer(msg)::Ptr{UInt8})::Int32
    @symbolcall exit(Int32(1)::Int32)::Int32
    return
end

# The path of the file that has the table (the program, or the shared library that it is part of) in `buffer`, which has room for `cap` bytes: its length, or 0
# if the system doesn't say, or says a path that is not absolute (the name that the program was started with)
@noinline function image_path(buffer::UInt, cap::Int)
    info = UInt(calloc(4, 8)) # (`Dl_info`: the file name, ...)
    info == 0 && out_of_memory()
    ok = @symbolcall dladdr(Ptr{Cvoid}(table())::Ptr{Cvoid}, Ptr{Cvoid}(info)::Ptr{Cvoid})::Int32
    fname = ld(info, 0)
    free(Ptr{UInt8}(info))
    (ok == 0 || fname == 0 || byte(fname, 0) != UInt8('/')) && return 0
    n = cstring_length(fname)
    n >= cap && return 0
    i = 0
    while i <= n
        unsafe_store!(Ptr{UInt8}(buffer), byte(fname, i), i + 1)
        i += 1
    end
    return n
end

# The folder of the program, as a C string that is never freed (or 1: not known): the path of the file up to its last slash.
@noinline function program_directory()
    d = sget(S_DIRECTORY)
    d != 0 && return d
    cap = 4096
    buffer = UInt(calloc(1, cap + 1))
    buffer == 0 && out_of_memory()
    n = image_path(buffer, cap)
    n == 0 && (n = executable_path(buffer, cap))
    if n <= 0
        free(Ptr{UInt8}(buffer))
        sset(S_DIRECTORY, UInt(1))
        return UInt(1)
    end
    # (up to the last slash, which is replaced by the end of the string; "/" if it is the first character, and "." if there is none)
    k = n
    while k > 0 && byte(buffer, k - 1) != UInt8('/')
        k -= 1
    end
    if k > 1
        unsafe_store!(Ptr{UInt8}(buffer), 0x00, k) # (the byte at index k - 1)
    elseif k == 1
        unsafe_store!(Ptr{UInt8}(buffer), 0x00, 2)
    else
        unsafe_store!(Ptr{UInt8}(buffer), UInt8('.'), 1)
        unsafe_store!(Ptr{UInt8}(buffer), 0x00, 2)
    end
    sset(S_DIRECTORY, buffer)
    return buffer
end

# the path of the running program in `buffer`, which has room for `cap` bytes: its length, or 0
@static if Sys.islinux()
    @inline function executable_path(buffer::UInt, cap::Int)
        path = c"/proc/self/exe"
        n = GC.@preserve path @symbolcall readlink(pointer(path)::Ptr{UInt8}, Ptr{UInt8}(buffer)::Ptr{UInt8}, cap::Int)::Int
        return n < 0 ? 0 : n
    end
elseif Sys.isapple()
    @inline function executable_path(buffer::UInt, cap::Int)
        size = UInt(calloc(1, 8))
        size == 0 && out_of_memory()
        unsafe_store!(Ptr{UInt32}(size), UInt32(cap))
        ok = @symbolcall _NSGetExecutablePath(Ptr{UInt8}(buffer)::Ptr{UInt8}, Ptr{UInt32}(size)::Ptr{UInt32})::Int32
        free(Ptr{UInt8}(size))
        return ok != 0 ? 0 : cstring_length(buffer)
    end
else
    @inline executable_path(buffer::UInt, cap::Int) = 0
end

# the path `directory/lib/name` as a new C string (to be freed)
@noinline function bundled_path(directory::UInt, name::UInt)
    nd, nn = cstring_length(directory), cstring_length(name)
    p = UInt(calloc(1, nd + nn + 6))
    p == 0 && out_of_memory()
    i = 0
    while i < nd
        unsafe_store!(Ptr{UInt8}(p), byte(directory, i), i + 1)
        i += 1
    end
    lib = c"/lib/"
    GC.@preserve lib begin
        j = 0
        while j < 5
            unsafe_store!(Ptr{UInt8}(p), unsafe_load(pointer(lib), j + 1), nd + j + 1)
            j += 1
        end
    end
    k = 0
    while k < nn
        unsafe_store!(Ptr{UInt8}(p), byte(name, k), nd + 5 + k + 1)
        k += 1
    end
    return p
end

# the handle of the library number `j` (from 0), opened with those that it needs before it
@noinline function open_library(j::Int)
    handles = sget(S_HANDLES)
    h = ld(handles, j)
    h != 0 && return h
    tbl = table()
    nlibs = ld(tbl, 0) % Int
    entry = 2 + 4j
    path = ld(tbl, entry)
    name = ld(tbl, entry + 1)
    deps = ld(tbl, entry + 2)
    if deps != 0
        n = ld(deps, 0) % Int
        k = 0
        while k < n
            open_library(ld(deps, 1 + k) % Int)
            k += 1
        end
    end
    h = UInt(0)
    if name != 0
        directory = program_directory()
        if directory != 1
            p = bundled_path(directory, name)
            h = UInt(@symbolcall dlopen(Ptr{UInt8}(p)::Ptr{UInt8}, RTLD_NOW::Int32)::Ptr{Cvoid})
            free(Ptr{UInt8}(p))
        end
    end
    if h == 0
        h = UInt(@symbolcall dlopen(Ptr{UInt8}(path)::Ptr{UInt8}, RTLD_NOW::Int32)::Ptr{Cvoid})
    end
    if h == 0
        what = c"cannot open"
        GC.@preserve what fail(UInt(pointer(what)), path)
    end
    st(handles, j, h)
    return h
end

# the function number `i` (from 0) of the table, found when it is first needed
function symbol(i::Int)
    cache = sget(S_SYMBOLS)
    if cache == 0
        tbl = table()
        nlibs, nsyms = ld(tbl, 0) % Int, ld(tbl, 1) % Int
        handles = UInt(calloc(max(nlibs, 1), 8))
        cache = UInt(calloc(max(nsyms, 1), 8))
        (handles == 0 || cache == 0) && out_of_memory()
        sset(S_HANDLES, handles)
        sset(S_SYMBOLS, cache)
    end
    f = ld(cache, i)
    f != 0 && return Ptr{UInt8}(f)
    tbl = table()
    nlibs = ld(tbl, 0) % Int
    entry = 2 + 4nlibs + 2i
    h = open_library(ld(tbl, entry) % Int)
    name = ld(tbl, entry + 1)
    f = UInt(@symbolcall dlsym(Ptr{UInt8}(h)::Ptr{UInt8}, Ptr{UInt8}(name)::Ptr{UInt8})::Ptr{Cvoid})
    if f == 0
        what = c"has no function"
        GC.@preserve what fail(UInt(pointer(what)), name)
    end
    st(cache, i, f)
    return Ptr{UInt8}(f)
end

end # module Loader
