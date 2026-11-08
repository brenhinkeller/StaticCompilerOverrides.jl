# Functions of other libraries, that `ccall`s name by library (`ccall((:erfc, libopenlibm), ...)`, as SpecialFunctions, and so
# Distributions, do), which Julia looks up when the call is first made, with `dlopen` and `dlsym` of its own (`ijl_lazy_load_and_lookup`).
#
# * The functions of the math library that the machine has (libm has the same names and meanings as openlibm, the one that Julia has)
#   are called by their names, and the linker finds them. The values can differ in the last bit from openlibm's.
# * The functions of other libraries (a JLL: OpenSpecFun, GMP, ...) are looked up when the program runs, with `dlopen` of the path
#   of the library when the program was compiled, as it is with libblastrampoline (see `blas.jl`): the program is not
#   independent of that file.
# Not those of the libraries of the runtime of Julia itself: they are what the program does not have.

using Libdl: Libdl

const LIBM_PREFIXES = ("libopenlibm", "libm.", "libm-")
const RUNTIME_LIBRARIES = ("libjulia", "libuv", "libLLVM", "libccalltest", "libsuitesparse") # (those that need the Julia runtime)

# the Julia object that a constant operand refers to: the address of one, or the value of a global that holds one (a `load` of
# an address, as a variable that is not a constant is read)
function constant_object(op)
    if op isa LLVM.LoadInst
        p = LLVM.operands(op)[1]
        nodes = inttoptr_nodes(p)
        length(nodes) == 1 || return nothing
        addr = constant_address(nodes[1])
        (addr === nothing || addr < 4096) && return nothing
        safe_load(UInt(addr)) === nothing && return nothing
        addr = unsafe_load(Ptr{UInt}(UInt(addr)))
    else
        nodes = inttoptr_nodes(op)
        length(nodes) == 1 || return nothing
        addr = constant_address(nodes[1])
    end
    (addr === nothing || addr < 4096) && return nothing
    object_type(UInt(addr)) === nothing && return nothing
    return unsafe_pointer_to_objref(Ptr{Cvoid}(UInt(addr)))
end

# the path of a library as a name (a `LazyLibrary`, or a name), and its handle in this process
function library_path(lib)
    lib isa Libdl.LazyLibrary && return string(lib.path)
    lib isa AbstractString && return String(lib)
    return nothing
end

# The lookups of `mod` that can be resolved: the names of those that are called by name (libm), and, of the others, the paths of
# the libraries and the (library number, name) of the functions, which `link_libraries!` makes the lookups of when the program
# runs. The calls are replaced: by the function, or by `static_library_symbol(i)`.
function resolve_library_lookups!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "ijl_lazy_load_and_lookup") || return String[], Tuple{Int,String}[]
    paths = String[]
    symbols = Tuple{Int,String}[]
    getter = nothing
    sentinel = nothing
    i64 = LLVM.Int64Type()
    for use in collect(LLVM.uses(fns["ijl_lazy_load_and_lookup"]))
        call = LLVM.user(use)
        call isa LLVM.CallInst || continue
        ops = LLVM.operands(call)
        lib_op = ops[1]
        lib, sym = constant_object(lib_op), constant_object(ops[2])
        (sym isa Union{Symbol,String}) || continue
        path = library_path(lib)
        path === nothing && continue
        name = String(sym)
        base = basename(path)
        any(p -> startswith(base, p), RUNTIME_LIBRARIES) && continue
        handle = try Libdl.dlopen(lib isa Libdl.LazyLibrary ? lib : path, throw_error = false) catch; nothing end
        (handle !== nothing && Libdl.dlsym_e(handle, name) != C_NULL) || continue
        if any(p -> startswith(base, p), LIBM_PREFIXES)
            fn = haskey(fns, name) ? fns[name] : LLVM.Function(mod, name, LLVM.FunctionType(LLVM.VoidType()))
            LLVM.replace_uses!(call, fn)
        else
            full = Libdl.dlpath(handle)
            lib_index = something(findfirst(==(full), paths), 0)
            if lib_index == 0
                push!(paths, full)
                lib_index = length(paths)
            end
            index = something(findfirst(==((lib_index, name)), symbols), 0)
            if index == 0
                push!(symbols, (lib_index, name))
                index = length(symbols)
            end
            getter === nothing && (getter = haskey(fns, "static_library_symbol") ? fns["static_library_symbol"] :
                                            LLVM.Function(mod, "static_library_symbol", LLVM.FunctionType(LLVM.PointerType(), [i64])))
            LLVM.@dispose builder = LLVM.IRBuilder() begin
                LLVM.position!(builder, LLVM.before(call))
                found = LLVM.call!(builder, LLVM.function_type(getter), getter, [LLVM.ConstantInt(i64, index - 1)])
                LLVM.replace_uses!(call, found)
            end
        end
        LLVM.erase!(call)
        # (the library was loaded from a variable, which is tested to be defined: it is, with the lookup resolved)
        if lib_op isa LLVM.LoadInst
            sentinel === nothing && (sentinel = library_sentinel(mod))
            LLVM.replace_uses!(lib_op, sentinel)
            isempty(collect(LLVM.uses(lib_op))) && LLVM.erase!(lib_op)
        end
    end
    return paths, symbols
end

# a non-null pointer that stands for the library that a variable held
function library_sentinel(mod::LLVM.Module)
    g = LLVM.GlobalVariable(mod, LLVM.Int8Type(), "static_library_sentinel")
    LLVM.initializer!(g, LLVM.ConstantInt(LLVM.Int8Type(), 0))
    LLVM.linkage!(g, LLVM.API.LLVMInternalLinkage)
    LLVM.constant!(g, true)
    return g
end

# `static_library_symbol(i)`: the function number `i` of the libraries, which are loaded the first time that one of their functions is needed
function library_loader_ir(paths::Vector{String}, symbols::Vector{Tuple{Int,String}})
    k, n = length(paths), length(symbols)
    io = IOBuffer()
    println(io, "declare ptr @dlopen(ptr, i32)\ndeclare ptr @dlsym(ptr, ptr)\ndeclare i32 @puts(ptr)\ndeclare void @exit(i32)")
    print(io, llvm_cstring("lib.noload", "Cannot load a library that the program calls functions of (it was at the path that it had when compiling)"))
    print(io, llvm_cstring("lib.nosymbol", "A function of a library is not in it"))
    for (j, path) in enumerate(paths)
        print(io, llvm_cstring("lib.path$j", path))
    end
    for (j, (_, name)) in enumerate(symbols)
        print(io, llvm_cstring("lib.name$j", name))
    end
    println(io, "@lib.paths = private constant [$k x ptr] [", join(("ptr @lib.path$j" for j in 1:k), ", "), "]")
    println(io, "@lib.names = private constant [$n x ptr] [", join(("ptr @lib.name$j" for j in 1:n), ", "), "]")
    println(io, "@lib.which = private constant [$n x i64] [", join(("i64 $(lib - 1)" for (lib, _) in symbols), ", "), "]")
    println(io, "@lib.handles = internal global [$k x ptr] zeroinitializer, align 8")
    println(io, "@lib.table = internal global [$n x ptr] zeroinitializer, align 8")
    println(io, """
define ptr @static_library_symbol(i64 %i) {
entry:
  %slot = getelementptr inbounds [$n x ptr], ptr @lib.table, i64 0, i64 %i
  %cached = load ptr, ptr %slot, align 8
  %have = icmp ne ptr %cached, null
  br i1 %have, label %done, label %lookup
done:
  ret ptr %cached
lookup:
  %wp = getelementptr inbounds [$n x i64], ptr @lib.which, i64 0, i64 %i
  %w = load i64, ptr %wp, align 8
  %hp = getelementptr inbounds [$k x ptr], ptr @lib.handles, i64 0, i64 %w
  %h0 = load ptr, ptr %hp, align 8
  %loaded = icmp ne ptr %h0, null
  br i1 %loaded, label %find, label %open
open:
  %pp = getelementptr inbounds [$k x ptr], ptr @lib.paths, i64 0, i64 %w
  %path = load ptr, ptr %pp, align 8
  %h = call ptr @dlopen(ptr %path, i32 2)
  %ok = icmp ne ptr %h, null
  br i1 %ok, label %opened, label %noload
noload:
  %r = call i32 @puts(ptr @lib.noload)
  call void @exit(i32 1)
  unreachable
opened:
  store ptr %h, ptr %hp, align 8
  br label %find
find:
  %h1 = load ptr, ptr %hp, align 8
  %np = getelementptr inbounds [$n x ptr], ptr @lib.names, i64 0, i64 %i
  %name = load ptr, ptr %np, align 8
  %sym = call ptr @dlsym(ptr %h1, ptr %name)
  %found = icmp ne ptr %sym, null
  br i1 %found, label %store, label %nosymbol
store:
  store ptr %sym, ptr %slot, align 8
  ret ptr %sym
nosymbol:
  %r2 = call i32 @puts(ptr @lib.nosymbol)
  call void @exit(i32 1)
  unreachable
}""")
    return String(take!(io))
end

function link_libraries!(mod::LLVM.Module, paths::Vector{String}, symbols::Vector{Tuple{Int,String}})
    isempty(symbols) && return false
    @debug "Functions of libraries, looked up when the program runs" paths symbols
    lib = parse(LLVM.Module, library_loader_ir(paths, symbols))
    LLVM.datalayout!(lib, LLVM.datalayout(mod))
    LLVM.triple!(lib, LLVM.triple(mod))
    LLVM.link!(mod, lib)
    return true
end
