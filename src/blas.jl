# BLAS and LAPACK, through libblastrampoline (LBT) as in Julia.
#
# What `LinearAlgebra` calls is the functions of LBT, which forwards each to the library that backs it (OpenBLAS by
# default; `AppleAccelerate.jl` and `MKL.jl` change that by `BLAS.lbt_forward`). The library that a program uses is that
# which is set when it is compiled, so it is the user's: the binary does what `LinearAlgebra` and those packages do. When it
# first needs a function of LBT, it loads LBT (`dlopen`), forwards to the libraries that were forwarded to when compiling,
# in the same order and with the same suffixes, and looks the function up (`dlsym`). Julia binds a `ccall` of a function of
# a library in the same way, lazily (`ijl_lazy_load_and_lookup`): here the lookup is the `static_blas_symbol` below, with the
# names of the functions that the program calls (and nothing is loaded if it does not call any).
#
# So a program that calls BLAS needs, when it is run, the libraries that were used when compiling it, at the places that they
# were (they are not in the binary): LBT, and what it forwards to.

# LinearAlgebra, if it is loaded (it is, when a program calls BLAS: what is looked up is its LazyLibrary)
function linear_algebra()
    id = Base.PkgId(Base.UUID("37e2e46d-f89d-539d-b4ee-838fcccc9c8e"), "LinearAlgebra")
    return get(Base.loaded_modules, id, nothing)
end

# the path of LBT, and the libraries that it forwards to now as (path, suffix), in the order that they were loaded in:
# those that something is forwarded to (a library that `clear` emptied is not)
function blas_setup(LA::Module)
    BLAS = LA.BLAS
    lbt = Base.Libc.Libdl.dlpath(BLAS.libblastrampoline)
    libs = Tuple{String,String}[]
    for lib in BLAS.get_config().loaded_libs
        any(!iszero, lib.active_forwards) && push!(libs, (lib.libname, lib.suffix))
    end
    return lbt, libs
end

# the functions of LBT that `mod` looks up (as `ccall`s are), replaced by a call of `static_blas_symbol(i)`, `i` being the
# index in the list that is returned. Done before the constants are embedded: what the call is given is not needed.
function resolve_blas_lookups!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "ijl_lazy_load_and_lookup") || return String[]
    LA = linear_algebra()
    LA === nothing && return String[]
    names = String[]
    i64 = LLVM.Int64Type()
    ptrT = LLVM.PointerType()
    getter = nothing
    for use in collect(LLVM.uses(fns["ijl_lazy_load_and_lookup"]))
        call = LLVM.user(use)
        call isa LLVM.CallInst || continue
        ops = LLVM.operands(call)
        objects = map((ops[1], ops[2])) do op
            nodes = inttoptr_nodes(op)
            length(nodes) == 1 || return nothing
            addr = constant_address(nodes[1])
            (addr === nothing || addr < 4096) && return nothing
            object_type(UInt(addr)) === nothing && return nothing
            return unsafe_pointer_to_objref(Ptr{Cvoid}(UInt(addr)))
        end
        (objects[1] === LA.BLAS.libblastrampoline && objects[2] isa Union{Symbol,String}) || continue
        name = String(objects[2])
        index = something(findfirst(==(name), names), 0)
        if index == 0
            push!(names, name)
            index = length(names)
        end
        getter === nothing && (getter = haskey(fns, "static_blas_symbol") ? fns["static_blas_symbol"] :
                                        LLVM.Function(mod, "static_blas_symbol", LLVM.FunctionType(ptrT, [i64])))
        LLVM.@dispose builder = LLVM.IRBuilder() begin
            LLVM.position!(builder, LLVM.before(call))
            found = LLVM.call!(builder, LLVM.function_type(getter), getter, [LLVM.ConstantInt(i64, index - 1)])
            LLVM.replace_uses!(call, found)
        end
        LLVM.erase!(call)
    end
    return names
end

# the IR that is a C string, as a global of the name
llvm_cstring(name, s) = "@$name = private unnamed_addr constant [$(ncodeunits(s) + 1) x i8] c\"" *
    join((b in 0x20:0x7e && b != UInt8('"') && b != UInt8('\\') ? string(Char(b)) : "\\" * uppercase(string(b, base = 16, pad = 2))
          for b in codeunits(s))) * "\\00\", align 1\n"

# `static_blas_symbol(i)`: the function of LBT of the name number `i`, loading LBT when it is needed the first time
function blas_loader_ir(lbt::String, libs, names::Vector{String})
    n = length(names)
    io = IOBuffer()
    println(io, "declare ptr @dlopen(ptr, i32)\ndeclare ptr @dlsym(ptr, ptr)\ndeclare i32 @puts(ptr)\ndeclare void @exit(i32)")
    print(io, llvm_cstring("blas.lbt", lbt))
    print(io, llvm_cstring("blas.forward", "lbt_forward"))
    print(io, llvm_cstring("blas.noload", "Cannot load libblastrampoline (for BLAS), which was at $lbt when compiling"))
    print(io, llvm_cstring("blas.nosymbol", "A function of BLAS or LAPACK is not in libblastrampoline"))
    for (k, name) in enumerate(names)
        print(io, llvm_cstring("blas.name$k", name))
    end
    for (k, (path, suffix)) in enumerate(libs)
        print(io, llvm_cstring("blas.lib$k", path))
        print(io, llvm_cstring("blas.suffix$k", suffix))
    end
    println(io, "@blas.names = private constant [$n x ptr] [", join(("ptr @blas.name$k" for k in 1:n), ", "), "]")
    println(io, "@blas.table = internal global [$n x ptr] zeroinitializer, align 8")
    println(io, "@blas.handle = internal global ptr null, align 8")
    println(io, """
define ptr @static_blas_symbol(i64 %i) {
entry:
  %slot = getelementptr inbounds [$n x ptr], ptr @blas.table, i64 0, i64 %i
  %cached = load ptr, ptr %slot, align 8
  %have = icmp ne ptr %cached, null
  br i1 %have, label %done, label %lookup
done:
  ret ptr %cached
lookup:
  %h0 = load ptr, ptr @blas.handle, align 8
  %loaded = icmp ne ptr %h0, null
  br i1 %loaded, label %find, label %open
open:
  %h = call ptr @dlopen(ptr @blas.lbt, i32 2)
  %ok = icmp ne ptr %h, null
  br i1 %ok, label %forward, label %noload
noload:
  %r = call i32 @puts(ptr @blas.noload)
  call void @exit(i32 1)
  unreachable
forward:
  store ptr %h, ptr @blas.handle, align 8
  %fwd = call ptr @dlsym(ptr %h, ptr @blas.forward)""")
    for (k, (path, suffix)) in enumerate(libs)
        hint = isempty(suffix) ? "ptr null" : "ptr @blas.suffix$k"
        println(io, "  %f$k = call i32 %fwd(ptr @blas.lib$k, i32 0, i32 0, $hint)")
    end
    println(io, """
  br label %find
find:
  %h1 = load ptr, ptr @blas.handle, align 8
  %np = getelementptr inbounds [$n x ptr], ptr @blas.names, i64 0, i64 %i
  %name = load ptr, ptr %np, align 8
  %sym = call ptr @dlsym(ptr %h1, ptr %name)
  %found = icmp ne ptr %sym, null
  br i1 %found, label %store, label %nosymbol
store:
  store ptr %sym, ptr %slot, align 8
  ret ptr %sym
nosymbol:
  %r2 = call i32 @puts(ptr @blas.nosymbol)
  call void @exit(i32 1)
  unreachable
}""")
    return String(take!(io))
end

# define `static_blas_symbol` in `mod`, for the functions `names` that `resolve_blas_lookups!` found
function link_blas!(mod::LLVM.Module, names::Vector{String})
    isempty(names) && return false
    lbt, libs = blas_setup(linear_algebra())
    @debug "BLAS through libblastrampoline" lbt libs names
    blas = parse(LLVM.Module, blas_loader_ir(lbt, libs, names))
    LLVM.datalayout!(blas, LLVM.datalayout(mod))
    LLVM.triple!(blas, LLVM.triple(mod))
    LLVM.link!(mod, blas)
    return true
end

# A large call of BLAS can be cancelled when its task is (Julia 1.14: `@ccall(cancel_handler = (@cfunction(_cancel_handler, ...)))`,
# after finding out whether the BLAS has what it needs, `_cancel_detect`). There are no tasks, so the handler, which is a C
# function that calls Julia code, never runs, and there is nothing to find out: neither has a body.
function stub_cancel_handlers!(mod::LLVM.Module)
    changed = false
    for fn in LLVM.functions(mod)
        name = LLVM.name(fn)
        (startswith(name, "jlcapi__cancel_handler") || startswith(name, "julia__cancel_detect")) && !LLVM.isdeclaration(fn) || continue
        LLVM.return_type(LLVM.function_type(fn)) == LLVM.VoidType() || continue
        for bb in collect(LLVM.blocks(fn))
            LLVM.erase!(bb)
        end
        LLVM.@dispose builder = LLVM.IRBuilder() begin
            entry = LLVM.BasicBlock(fn, "entry")
            LLVM.position!(builder, LLVM.at_end(entry))
            LLVM.ret!(builder)
        end
        changed = true
    end
    if changed
        # (the stubs that `ccall`s are bound through are used by their globals, which are visible, and so are not removed)
        for g in LLVM.globals(mod)
            name = LLVM.name(g)
            (startswith(name, "jlplt_") || startswith(name, "ccall_")) && LLVM.linkage!(g, LLVM.API.LLVMInternalLinkage)
        end
        run!(GlobalDCEPass(), mod) # (what only the functions that were stubbed used)
    end
    return changed
end
