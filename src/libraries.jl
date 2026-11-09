# Functions of other libraries, that `ccall`s name by library (`ccall((:erfc, libopenlibm), ...)`, as SpecialFunctions, and so
# Distributions, do), which Julia looks up when the call is first made, with `dlopen` and `dlsym` of its own (`ijl_lazy_load_and_lookup`).
#
# * The functions of the math library that the machine has (libm has the same names and meanings as openlibm, the one that Julia has)
#   are called by their names, and the linker finds them. The values can differ in the last bit from openlibm's.
# * The functions of other libraries (a JLL: OpenSpecFun, GMP, MPFR, PCRE2, zlib, ...; a library of the user's) are looked up when the program
#   runs, by the loader (`loader.jl`): `dlopen` of the library, after those that it needs, and `dlsym`. Which libraries, and where they are, is a
#   table that is written for the program. Where a library is looked for is the choice `libraries`:
#     - `:system` (the default): at the path that it had when the program was compiled (the program is not independent of that file, as it is with
#       libblastrampoline, see `blas.jl`);
#     - `:bundle`: in the folder `lib` next to the program, where the files (and those that they need) are copied when compiling, and then, if
#       they are not there, at the path that they had.
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

# The libraries that the program calls functions of: their paths (as they are in this process), those that each needs (their numbers), and the
# functions, as (library number, name)
struct LibraryPlan
    paths::Vector{String}
    needs::Vector{Vector{Int}}
    symbols::Vector{Tuple{Int,String}}
end
LibraryPlan() = LibraryPlan(String[], Vector{Int}[], Tuple{Int,String}[])

# Where a library is that is part of the system: it is not copied with the program, and is found by its name
system_library(path::AbstractString) = any(p -> startswith(path, p), ("/usr/lib/", "/System/", "/lib/", "/lib64/", "/usr/lib64/", "/usr/lib32/"))

# The libraries that the library `lib` (at `path`) needs, as (library, handle) that are loaded in this process: those that its `LazyLibrary` has,
# and, when they are to be copied, those that the file says (`otool -L`, or `ldd`) that are not of the system.
function library_needs(lib, path::String, libraries::Symbol)
    needs = Tuple{Any,Any}[]
    if lib isa Libdl.LazyLibrary
        deps = lib.dependencies
        deps isa AbstractVector || (deps = deps()) # (Julia 1.14: a `OncePerProcess` that makes the list)
        for d in deps
            h = try Libdl.dlopen(d, throw_error = false) catch; nothing end
            h === nothing || push!(needs, (d, h))
        end
    end
    libraries === :bundle || return needs
    names = String[]
    try
        if Sys.isapple()
            for line in split(read(`otool -L $path`, String), '\n')[2:end]
                m = match(r"^\s+(\S+)", line)
                m === nothing || push!(names, basename(m.captures[1]))
            end
        elseif Sys.islinux()
            for line in split(read(`ldd $path`, String), '\n')
                m = match(r"^\s*(\S+)\s+=>\s+(\S+)", line)
                m === nothing || push!(names, basename(m.captures[2]))
            end
        end
    catch
    end
    loaded = Libdl.dllist()
    for name in unique(names)
        name == basename(path) && continue
        found = findfirst(p -> basename(p) == name && !system_library(p), loaded)
        found === nothing && continue
        any(n -> n[1] isa Libdl.LazyLibrary && basename(string(n[1].path)) == name, needs) && continue
        h = Libdl.dlopen(loaded[found], throw_error = false)
        h === nothing || push!(needs, (loaded[found], h))
    end
    return needs
end

# the number of the library (a new one is added, with those that it needs before it)
function register_library!(plan::LibraryPlan, lib, handle, libraries::Symbol)
    full = Libdl.dlpath(handle)
    i = findfirst(==(full), plan.paths)
    i === nothing || return i
    push!(plan.paths, full)
    push!(plan.needs, Int[])
    i = length(plan.paths)
    needs = Int[]
    for (dlib, dh) in library_needs(lib, full, libraries)
        j = register_library!(plan, dlib, dh, libraries)
        j == i || push!(needs, j)
    end
    plan.needs[i] = needs
    return i
end

# The lookups of `mod` that can be resolved: the names of those that are called by name (libm), and, of the others, the libraries and the
# functions, which the loader makes the lookups of when the program runs. The calls are replaced: by the function, or by `static_library_symbol(i)`.
function resolve_library_lookups!(mod::LLVM.Module; libraries::Symbol = :system)
    fns = LLVM.functions(mod)
    plan = LibraryPlan()
    getter = nothing
    sentinel = nothing
    i64 = LLVM.Int64Type()
    # the two forms of the lookup: `ijl_lazy_load_and_lookup(library object, symbol)` (a `LazyLibrary`, or a name that is a
    # constant) and `ijl_load_and_lookup(library name, symbol name, handle)` (a name that is a string)
    calls = LLVM.CallInst[]
    for f in ("ijl_lazy_load_and_lookup", "ijl_load_and_lookup")
        haskey(fns, f) || continue
        append!(calls, (LLVM.user(use) for use in LLVM.uses(fns[f]) if LLVM.user(use) isa LLVM.CallInst))
    end
    for call in calls
        ops = LLVM.operands(call)
        lib_op = ops[1]
        if LLVM.name(LLVM.called_operand(call)) == "ijl_load_and_lookup"
            libname, name = constant_cstring(lib_op), constant_cstring(ops[2])
            (libname === nothing || name === nothing) && continue
            (name in RUNTIME_SHIM_FUNCTIONS || name in LIBC_FUNCTIONS) && continue
            lib = libname
        else
            lib, sym = constant_object(lib_op), constant_object(ops[2])
            (sym isa Union{Symbol,String}) || continue
            name = String(sym)
        end
        path = library_path(lib)
        path === nothing && continue
        base = basename(path)
        any(p -> startswith(base, p), RUNTIME_LIBRARIES) && continue
        handle = open_library(lib)
        (handle !== nothing && Libdl.dlsym_e(handle, name) != C_NULL) || continue
        if any(p -> startswith(base, p), LIBM_PREFIXES)
            fn = haskey(fns, name) ? fns[name] : LLVM.Function(mod, name, LLVM.FunctionType(LLVM.VoidType()))
            LLVM.replace_uses!(call, fn)
        else
            lib_index = register_library!(plan, lib, handle, libraries)
            index = something(findfirst(==((lib_index, name)), plan.symbols), 0)
            if index == 0
                push!(plan.symbols, (lib_index, name))
                index = length(plan.symbols)
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
    return plan
end

# The handle of a library given as a `LazyLibrary` or as a name, in this process, as Julia finds it (a name like "libz" has the
# extension of the platform added, and the names of the ones that were linked with `@rpath` are looked for by their file name).
function open_library(lib)
    lib isa Libdl.LazyLibrary && return try Libdl.dlopen(lib, throw_error = false) catch; nothing end
    name = String(lib)
    candidates = [name, name * "." * Libdl.dlext, basename(name), basename(name) * "." * Libdl.dlext]
    for c in candidates
        h = Libdl.dlopen(c, throw_error = false)
        h === nothing || return h
    end
    return nothing
end

# a non-null pointer that stands for the library that a variable held
function library_sentinel(mod::LLVM.Module)
    g = LLVM.GlobalVariable(mod, LLVM.Int8Type(), "static_library_sentinel")
    LLVM.initializer!(g, LLVM.ConstantInt(LLVM.Int8Type(), 0))
    LLVM.linkage!(g, LLVM.API.LLVMInternalLinkage)
    LLVM.constant!(g, true)
    return g
end

# The table that the loader reads (see `loader.jl`), as the text of a module
function library_table_ir(plan::LibraryPlan, libraries::Symbol)
    k, n = length(plan.paths), length(plan.symbols)
    io = IOBuffer()
    words = String[string("i64 ", k), string("i64 ", n)]
    for (j, path) in enumerate(plan.paths)
        print(io, llvm_cstring("lib.path$j", path))
        push!(words, "i64 ptrtoint (ptr @lib.path$j to i64)")
        if libraries === :bundle && !system_library(path)
            print(io, llvm_cstring("lib.base$j", basename(path)))
            push!(words, "i64 ptrtoint (ptr @lib.base$j to i64)")
        else
            push!(words, "i64 0")
        end
        if isempty(plan.needs[j])
            push!(words, "i64 0")
        else
            println(io, "@lib.needs$j = private constant [$(1 + length(plan.needs[j])) x i64] [i64 $(length(plan.needs[j])), ",
                    join(("i64 $(d - 1)" for d in plan.needs[j]), ", "), "]")
            push!(words, "i64 ptrtoint (ptr @lib.needs$j to i64)")
        end
        push!(words, "i64 0")
    end
    for (j, (lib, name)) in enumerate(plan.symbols)
        print(io, llvm_cstring("lib.name$j", name))
        push!(words, "i64 $(lib - 1)", "i64 ptrtoint (ptr @lib.name$j to i64)")
    end
    println(io, "@_static_libs = hidden constant [$(length(words)) x i64] [", join(words, ", "), "], align 16")
    return String(take!(io))
end

const LOADER_IR = Ref{String}("")
function loader_ir()
    isempty(LOADER_IR[]) || return LOADER_IR[]
    loader = StaticCompiler.compile_llvm_module(Loader.symbol, (Int,), "static_library_symbol")
    try
        for fn in LLVM.functions(loader)
            LLVM.isdeclaration(fn) || LLVM.name(fn) == "static_library_symbol" || LLVM.linkage!(fn, LLVM.API.LLVMInternalLinkage)
        end
        for g in LLVM.globals(loader)
            LLVM.isdeclaration(g) || LLVM.linkage!(g, LLVM.API.LLVMInternalLinkage)
        end
        LOADER_IR[] = string(loader)
    finally
        LLVM.dispose(loader)
    end
    return LOADER_IR[]
end

# the libraries of the last program that was linked (what `libraries = :bundle` copies, when it has been compiled)
const LAST_LIBRARIES = Ref(LibraryPlan())

function link_libraries!(mod::LLVM.Module, plan::LibraryPlan; libraries::Symbol = :system)
    LAST_LIBRARIES[] = plan
    isempty(plan.symbols) && return false
    @debug "Functions of libraries, looked up when the program runs" plan.paths plan.symbols libraries
    for ir in (library_table_ir(plan, libraries), loader_ir())
        part = parse(LLVM.Module, ir)
        LLVM.datalayout!(part, LLVM.datalayout(mod))
        LLVM.triple!(part, LLVM.triple(mod))
        LLVM.link!(mod, part)
    end
    return true
end

# Copy the libraries of the program that was compiled to the folder `lib` next to it (`libraries = :bundle`)
function bundle_libraries(program::AbstractString)
    plan = LAST_LIBRARIES[]
    copied = String[]
    isempty(plan.symbols) && return copied
    dir = joinpath(dirname(abspath(program)), "lib")
    mkpath(dir)
    for path in plan.paths
        system_library(path) && continue
        target = joinpath(dir, basename(path))
        cp(path, target; force = true)
        push!(copied, target)
    end
    return copied
end
