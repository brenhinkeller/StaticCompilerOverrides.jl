# The object embedder: the objects of the process that compiles that the code refers to (a `const` array, a string, a type, ...) are copied into the binary, as globals, with the layout
# that Julia gives them (`ObjectEmbedder`). Each object is one global, whatever refers to it, and what it refers to is copied too (`embed_global!`, `object_pieces`).

# ## The objects that are copied into the binary: what it has to be, and what is checked
#
# Code that is compiled from a Julia process refers to the objects of that process by their addresses (`inttoptr (i64 N)`): a string, a
# `Vector`, a type, a `Dict` that is a `const`. A binary does not have the process, so the objects are copied into it (`embed_constants!`), and
# each address is replaced by the copy. Nothing says which numbers are addresses of objects and which are only numbers, and the memory of
# the process is not described anywhere that this can ask: so what is done is made of checks, each of which has to hold for an address to be
# an object, and each of which is the reason for a failure that the messages say (`JULIA_DEBUG=StaticRuntime`):
#
# 1. *An object is where its tag says.* The word before an address is its type tag: a small number (the builtin types), or the address of a
#    `DataType`. That `DataType` has to have the tag of a `DataType`, a name with the tag of a `TypeName`, a supertype with the tag of a
#    `DataType`, and `svec`s for its parameters and the types of its fields (`object_type`). Asking Julia anything about a "type" that does not
#    have these (`<:`, `isconcretetype`) can crash the process that compiles, so nothing is asked before they are known. The objects that have
#    no fields (a function, `nothing`) are 8 bytes after a 16-byte aligned cell, and are the `instance` of their type; symbols are 8-byte aligned too.
# 2. *Memory is read only where the kernel says that it is readable* (`safe_load`, `check_readable`): a word that looks like a pointer may
#    not be one.
# 3. *An address that is an object is that object.* An address that is the start of an object is not looked for in an object before it
#    (`find_objects`); only an address that is not (the data of a string, a field of a struct) is, up to `MAX_INTERIOR` bytes, and in an object
#    only if the object is large enough to have it.
# 4. *The objects are one each.* An object that is referred to twice (in two arrays, by two constants) is one object in the binary, by its
#    address in this process (`e.globals`), so `===` and cycles are as in Julia. An object that is being copied is in `e.globals` before
#    what it refers to is, which is how cycles are copied.
# 5. *What a program never reads is not copied*: the supertype, wrapper and field names of a type, the method tables, the caches of a type name
#    (`field_cut`). A program that reads them gets null, or an empty list.
# 6. *A copy that fails fails whole.* If an object can't be copied (a `Module`, a task, something that is not an object), it and what refers to it are
#    not, and the code that refers to its address stays as it was: strict mode refuses it, naming the address (`unresolved_pointer_uses`), and
#    `EMBED_FAILURES` has why.
#
# `test/testembedfuzz.jl` checks all of it together: random nested constants and what a program does to a copy of them, with what Julia computes
# from them as the answer, also with the collector run as often as it can.

# (the objects of the program that are in the binary, by the address that they have in this process)
mutable struct ObjectEmbedder
    mod::LLVM.Module
    globals::Dict{UInt,Union{LLVM.GlobalVariable,Nothing}} # object address => its global
    egal::Bool # whether the code compares objects with `jl_egal__unboxed`, and so needs the plans of the types for it
end

# (the plans are not made if nothing uses them: see `egal_layout!`)
# (`jl_genericmemory_copyto` is called through a stub, which is a global, until the lookups of functions are resolved)
calls_genericmemory_copyto(mod::LLVM.Module) = any(g -> startswith(LLVM.name(g), "jlplt_jl_genericmemory_copyto"), LLVM.globals(mod))

ObjectEmbedder(mod::LLVM.Module, globals) =
    ObjectEmbedder(mod, globals, haskey(LLVM.functions(mod), "jl_egal__unboxed") || calls_genericmemory_copyto(mod))

# an object we can't reproduce, and why
struct EmbedFailure <: Exception
    reason::String
end

EmbedFailure() = EmbedFailure("")

# Globals of the Julia runtime that hold a pointer to a well-known object (compiled code loads
# the pointer from the global). We make each point to a copy of the object in the binary.
const WELL_KNOWN_OBJECTS = (
    "jl_nothing" => nothing, "jl_emptytuple" => (), "jl_true" => true, "jl_false" => false,
    "jl_diverror_exception" => DivideError(), "jl_undefref_exception" => UndefRefError(),
    "jl_memory_exception" => OutOfMemoryError(), "jl_stackovf_exception" => StackOverflowError(),
    "jl_readonlymemory_exception" => ReadOnlyMemoryError(), "jl_interrupt_exception" => InterruptException(),
)

# The object in the binary that is the well-known object `obj` (which is one object, so that it is the one
# everything refers to, whether by its global, or by its address, as for any constant object, see
# `embed_global!`). It is preceded by its type tag as it is in this process.
function well_known_object!(e::ObjectEmbedder, name::AbstractString, obj)
    mod = e.mod
    globals = LLVM.globals(mod)
    haskey(globals, "static_$name") && return globals["static_$name"]
    addr = UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), obj))
    tag = unsafe_load(Ptr{UInt}(addr - 8)) & ~UInt(15)
    n = max(sizeof(typeof(obj)), 8) # room for at least a word, so that the address is a valid one
    payload = zeros(UInt8, n)
    sizeof(typeof(obj)) > 0 && unsafe_copyto!(pointer(payload), Ptr{UInt8}(addr), sizeof(typeof(obj)))
    st = LLVM.StructType([LLVM.Int64Type(), LLVM.Int64Type(), LLVM.ArrayType(LLVM.Int8Type(), n)]; packed = true)
    object = LLVM.GlobalVariable(mod, st, "static_$name")
    LLVM.linkage!(object, LLVM.API.LLVMLinkOnceODRLinkage)
    LLVM.visibility!(object, LLVM.API.LLVMHiddenVisibility)
    LLVM.alignment!(object, 16)
    # (the tag is of a type that may refer to this object: so after the global exists)
    LLVM.initializer!(object, LLVM.ConstantStruct(LLVM.Constant[LLVM.ConstantInt(Int64(0)), tag_piece(e, tag), LLVM.ConstantDataArray(LLVM.Int8Type(), payload)]; packed = true))
    return object
end

# which of the well-known objects is at an address, in this process
const WELL_KNOWN_ADDRESSES = Dict{UInt,Pair{String,Any}}()

function well_known_at(addr::UInt)
    if isempty(WELL_KNOWN_ADDRESSES)
        for (name, obj) in WELL_KNOWN_OBJECTS
            WELL_KNOWN_ADDRESSES[UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), obj))] = name => obj
        end
    end
    return get(WELL_KNOWN_ADDRESSES, addr, nothing)
end

function define_well_known_objects!(e::ObjectEmbedder)
    mod = e.mod
    changed = false
    for (name, obj) in WELL_KNOWN_OBJECTS
        globals = LLVM.globals(mod)
        haskey(globals, name) && LLVM.isdeclaration(globals[name]) || continue
        old = globals[name]
        object = well_known_object!(e, name, obj)
        pointer_to_object = LLVM.const_gep(LLVM.Int8Type(), object, [LLVM.ConstantInt(Int64(16))])
        LLVM.name!(old, name * ".declaration")
        new = LLVM.GlobalVariable(mod, LLVM.PointerType(), name)
        LLVM.initializer!(new, pointer_to_object)
        LLVM.constant!(new, true)
        LLVM.linkage!(new, LLVM.API.LLVMLinkOnceODRLinkage)
        LLVM.replace_uses!(old, new)
        LLVM.erase!(old)
        changed = true
    end
    return changed
end

const EMBED_ALIGN = 16

const EMBED_HEADER = 16 # the padding and the type tag before an object

# `LLVM` constants for the pieces of a global, to be laid out contiguously (packed)
bytes_piece(addr, n) = n == 0 ? nothing :
    LLVM.ConstantDataArray(LLVM.Int8Type(), copy(unsafe_wrap(Array, Ptr{UInt8}(addr), n)))

nullptr() = LLVM.PointerNull(LLVM.PointerType())

i64(x) = LLVM.ConstantInt(Int64(x))

# why the objects that could not be embedded could not (for the messages of the ones that refer to them)
const EMBED_FAILURES = Dict{UInt,String}()

function embed_global!(e::ObjectEmbedder, addr::UInt)
    if haskey(e.globals, addr)
        g = e.globals[addr]
        g === nothing && throw(EmbedFailure(string("an object that failed, or that it refers to: ", get(EMBED_FAILURES, addr, "(in progress)"))))
        return g
    end
    wk = well_known_at(addr)
    if wk !== nothing
        g = well_known_object!(e, first(wk), last(wk))
        e.globals[addr] = g
        return g
    end
    e.globals[addr] = nothing # failed, or in progress
    try
        return embed_new_global!(e, addr)
    catch err
        err isa EmbedFailure && !haskey(EMBED_FAILURES, addr) && (EMBED_FAILURES[addr] = first(replace(err.reason, '\n' => ' '), 300))
        if err isa EmbedFailure && !isempty(err.reason)
            # (the path, from the object that can't be reproduced to the one we wanted)
            path = count("\n  <- ", err.reason) < 12 ? string(err.reason, "\n  <- ", object_type(addr), " at ", string(addr, base = 16)) : err.reason
            err = EmbedFailure(path)
            e.globals[addr] = nothing
            throw(err)
        end
        rethrow()
    end
end

function embed_new_global!(e::ObjectEmbedder, addr::UInt)
    T = object_type(addr)
    T === nothing && throw(EmbedFailure("not an object, at $(string(addr, base = 16)): tag word $(repr(safe_load(addr - 8)))"))
    reason = something(address_hashed_reason(T, addr), runtime_binding_reason(T, addr), Some(nothing))
    reason === nothing || throw(EmbedFailure(reason))
    # `values` needs the global, since objects may refer to themselves or to each other
    types, values = object_pieces(e, T, addr)
    # Before the object, as in Julia: its type tag (as it is in this process: the code that was compiled compares
    # with these), preceded by padding that makes the object aligned to 16 bytes
    tag = safe_load(addr - 8)
    tag === nothing && throw(EmbedFailure("no tag"))
    types = LLVM.LLVMType[LLVM.Int64Type(), LLVM.Int64Type(), types...]
    st = LLVM.StructType(types; packed=true)
    g = LLVM.GlobalVariable(e.mod, st, "static_object_$(string(addr, base=16))")
    # One object, whichever of the functions of a library refers to it: the functions are compiled
    # (and their modules linked) separately, so the global has the same name (that has the address of
    # the object in it) in each, and they are merged. It is hidden, so that two libraries don't share it.
    LLVM.linkage!(g, LLVM.API.LLVMLinkOnceODRLinkage)
    LLVM.visibility!(g, LLVM.API.LLVMHiddenVisibility)
    LLVM.alignment!(g, EMBED_ALIGN)
    root_free(T) && (LLVM.metadata(g)["static.pointerfree"] = LLVM.MDNode(LLVM.Metadata[])) # (the collector doesn't look at it: see `define_gc_roots!`)
    e.globals[addr] = g
    try
        LLVM.initializer!(g, LLVM.ConstantStruct(LLVM.Constant[i64(0), tag_piece(e, tag & ~UInt(15)), values(g)...]; packed=true))
    catch
        e.globals[addr] = nothing
        LLVM.initializer!(g, LLVM.null(st))
        rethrow()
    end
    return g
end

# The tag of an object as the header of an embedded one: the small number of a builtin type, or the type: its
# address in the binary if it is one of those that are embedded (so that `isa` and `typeof` of the
# object have something to look at), and else its number in this process
function tag_piece(e::ObjectEmbedder, tag::UInt)
    tag < (64 << 4) && return i64(tag)
    ref = try
        embed_ref!(e, tag)
    catch err
        err isa EmbedFailure || rethrow()
        @debug "The type of an object is not in the binary, so its tag is a number" type = object_type(tag) reason = err.reason
        return i64(tag)
    end
    return LLVM.const_ptrtoint(ref, LLVM.Int64Type())
end

# a reference to the object at `addr` (or null), as an LLVM constant
function embed_ref!(e::ObjectEmbedder, addr::UInt, offset=0)
    addr == 0 && return nullptr()
    g = embed_global!(e, addr)
    return LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER + offset)])
end

function object_pieces(e::ObjectEmbedder, T::DataType, addr::UInt)
    if T === Module
        throw(EmbedFailure("a Module: a C struct of the runtime"))
    elseif T === Core.SimpleVector
        # { length, elements... }
        check_readable(addr, 8)
        n = unsafe_load(Ptr{Int}(addr))
        (0 <= n <= 100_000) || throw(EmbedFailure("implausible length of a svec"))
        check_readable(addr, 8 + 8n)
        refs = [unsafe_load(Ptr{UInt}(addr + 8 + 8(i - 1))) for i in 1:n]
        types = LLVM.LLVMType[LLVM.Int64Type(), (LLVM.PointerType() for _ in 1:n)...]
        return types, g -> LLVM.Constant[i64(n), (embed_ref!(e, r) for r in refs)...]
    elseif T === Symbol
        # { left, right (links of the table of symbols of the runtime), hash, name, NUL }: the name
        # is what is used, and as global constants are one object each, symbols are still egal
        check_readable(addr, 32)
        name_length = Int(ccall(:strlen, Csize_t, (Ptr{UInt8},), Ptr{UInt8}(addr + 24)))
        check_readable(addr, 24 + name_length + 1)
        types = LLVM.LLVMType[LLVM.PointerType(), LLVM.PointerType(), LLVM.Int64Type(), LLVM.ArrayType(LLVM.Int8Type(), name_length + 1)]
        hash = unsafe_load(Ptr{Int64}(addr + 16))
        return types, g -> LLVM.Constant[nullptr(), nullptr(), i64(hash), bytes_piece(addr + 24, name_length + 1)]
    elseif T === String
        check_readable(addr, 8)
        n = 8 + unsafe_load(Ptr{Int}(addr)) + 1
        check_readable(addr, n)
        return [LLVM.ArrayType(LLVM.Int8Type(), n)], g -> [bytes_piece(addr, n)]
    elseif T <: Core.GenericMemory
        return memory_pieces(e, T, addr)
    elseif isprimitivetype(T)
        # a boxed number, character, ...: its bytes
        n = sizeof(T)
        check_readable(addr, n)
        return LLVM.LLVMType[LLVM.ArrayType(LLVM.Int8Type(), n)], g -> LLVM.Constant[bytes_piece(addr, n)]
    elseif Base.issingletontype(T)
        # the one instance of the type (a function, a tuple of singletons: `(Val(true),)` has a field, and no size), which has no contents: padding, so that the object has an address
        pad = LLVM.ArrayType(LLVM.Int8Type(), 8)
        return LLVM.LLVMType[pad], g -> LLVM.Constant[LLVM.null(pad)]
    elseif fieldcount(T) > 0
        return struct_pieces(e, T, addr)
    end
    throw(EmbedFailure("objects of type $T are not supported"))
end

# { length, data pointer, data... } with the data inline, as for the memory Julia allocates
function memory_pieces(e::ObjectEmbedder, T, addr::UInt)
    ET = eltype(T)
    check_readable(addr, 16)
    len = unsafe_load(Ptr{Int}(addr))
    data = unsafe_load(Ptr{UInt}(addr + 8))
    ptrT = LLVM.PointerType()
    if len == 0 # nothing in it, of whatever type its elements are
        types = LLVM.LLVMType[LLVM.Int64Type(), ptrT]
        return types, g -> LLVM.Constant[i64(0), LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER + 16)])]
    elseif isbitstype(ET) && Base.datatype_pointerfree(ET) # plain data
        n = len * Base.aligned_sizeof(ET)
        check_readable(data, n)
        types = LLVM.LLVMType[LLVM.Int64Type(), ptrT, LLVM.ArrayType(LLVM.Int8Type(), n)]
        return types, g -> LLVM.Constant[i64(len), LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER + 16)]), something(bytes_piece(data, n), LLVM.null(types[3]))]
    elseif ET isa Union && Base.isbitsunion(ET) # a union of types without references (`Union{Int,Nothing}`): the values, then a byte for each, of its type
        n = len * Base.aligned_sizeof(ET) + len
        check_readable(data, n)
        types = LLVM.LLVMType[LLVM.Int64Type(), ptrT, LLVM.ArrayType(LLVM.Int8Type(), n)]
        return types, g -> LLVM.Constant[i64(len), LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER + 16)]), something(bytes_piece(data, n), LLVM.null(types[3]))]
    elseif !isbitstype(ET) && Base.allocatedinline(ET) == false # boxed elements (a union that has a type with references, `Union{Nothing,Symbol}`, is stored as references too)
        check_readable(data, 8 * len)
        refs = [unsafe_load(Ptr{UInt}(data + 8(i - 1))) for i in 1:len]
        types = LLVM.LLVMType[LLVM.Int64Type(), ptrT, (ptrT for _ in 1:len)...]
        return types, g -> LLVM.Constant[i64(len), LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER + 16)]), (embed_ref!(e, r) for r in refs)...]
    end
    if ET isa DataType && Base.allocatedinline(ET) # structs with references in them, stored in it
        check_readable(data, len * sizeof(ET))
        element_types, element_values = struct_pieces(e, ET, data; n=len)
        types = LLVM.LLVMType[LLVM.Int64Type(), ptrT, element_types...]
        return types, g -> LLVM.Constant[i64(len), LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER + 16)]), element_values(g)...]
    end
    throw(EmbedFailure("memory of $ET"))
end

# How `===` compares two objects of an immutable type, from the type, as the operations that the code for
# `jl_egal__unboxed` in the shim does (see there): comparing the contents of the fields in order, and the objects
# that the fields refer to. Julia's own `compare_fields` does this with the layout of the type and the types of its
# fields, which are not in the binary; this is what that comes to, for each type.
const EGAL_BYTES, EGAL_REF, EGAL_UNSUPPORTED = UInt32(0), UInt32(1), UInt32(2)

function egal_operations!(ops, dt::DataType, base::Int)
    for i in 1:fieldcount(dt)
        off = base + Int(fieldoffset(dt, i))
        ft = fieldtype(dt, i)
        if !Base.allocatedinline(ft)
            push!(ops, (EGAL_REF, off, 0))
        elseif !(ft isa DataType) || (fieldcount(ft) == 0 && Base.datatype_haspadding(ft))
            # (a field of a Union of types that are stored inline has a selector byte, and padding of the
            # types that have it is not compared)
            push!(ops, (EGAL_UNSUPPORTED, off, 0))
        elseif fieldcount(ft) == 0
            sizeof(ft) > 0 && push!(ops, (EGAL_BYTES, off, sizeof(ft)))
        else
            egal_operations!(ops, ft, off) # a struct that is stored inline in this one
        end
    end
    return ops
end

# the bytes of the memory before the `layout` of a type that has what `jl_egal__unboxed` needs: the operations,
# the number of them (negative for a mutable type), and then the layout as Julia has it. Its address is that of
# the layout. `nothing` for a type without a layout (an abstract one)
function egal_plan(dt::DataType)
    layout = unsafe_load(Ptr{Ptr{UInt8}}(pointer_from_objref(dt) + fieldoffset(DataType, findfirst(==(:layout), fieldnames(DataType)))))
    (layout == C_NULL || !isconcretetype(dt)) && return nothing
    # the size of the layout: its header, and the descriptions of the fields and the offsets of the pointers
    nfields, npointers = unsafe_load(Ptr{UInt32}(layout + 4)), unsafe_load(Ptr{UInt32}(layout + 8))
    fieldkind = Base.datatype_fielddesc_type(dt) + 1 # (8, 16 or 32 bit)
    layout_size = 20 + nfields * (2, 4, 8)[fieldkind] + npointers * (1, 2, 4)[fieldkind]
    ops = Tuple{UInt32,Int,Int}[]
    if ismutabletype(dt)
        count = -1
    else
        if fieldcount(dt) == 0 # a primitive type, or one without fields
            if sizeof(dt) > 0
                push!(ops, Base.datatype_haspadding(dt) ? (EGAL_UNSUPPORTED, 0, 0) : (EGAL_BYTES, 0, sizeof(dt)))
            end
        else
            egal_operations!(ops, dt, 0)
        end
        # (neighbors that are compared by bytes are one comparison)
        merged = Tuple{UInt32,Int,Int}[]
        for op in ops
            if !isempty(merged) && op[1] == EGAL_BYTES && merged[end][1] == EGAL_BYTES && merged[end][2] + merged[end][3] == op[2]
                merged[end] = (EGAL_BYTES, merged[end][2], merged[end][3] + op[3])
            else
                push!(merged, op)
            end
        end
        ops = merged
        count = length(ops)
    end
    io = IOBuffer()
    for (kind, off, size) in (count < 0 ? () : ops)
        write(io, kind, UInt32(off), UInt32(size), UInt32(0))
    end
    write(io, Int64(count))
    layout_offset = position(io)
    write(io, unsafe_wrap(Array, layout, layout_size))
    return take!(io), layout_offset
end

# The `layout` of the type at `addr` for the binary: a global with its plan (see `egal_plan`) and the layout
function egal_layout!(e::ObjectEmbedder, dt::DataType, addr::UInt)
    e.egal || return nullptr() # nothing compares objects: the type is not looked at
    plan = egal_plan(dt)
    plan === nothing && return nullptr()
    bytes, layout_offset = plan
    contents = LLVM.ConstantDataArray(LLVM.Int8Type(), bytes)
    g = LLVM.GlobalVariable(e.mod, LLVM.value_type(contents), "static_egal_$(string(addr, base=16))")
    LLVM.linkage!(g, LLVM.API.LLVMLinkOnceODRLinkage)
    LLVM.visibility!(g, LLVM.API.LLVMHiddenVisibility)
    LLVM.alignment!(g, EMBED_ALIGN)
    LLVM.initializer!(g, contents)
    return LLVM.const_gep(LLVM.Int8Type(), g, [i64(layout_offset)])
end

# The `types` of a type is a list that is as long as the type has fields (the code that checks an index against the
# number of the fields of a type reads its length): one of that length, of `nothing`s, stands for it.
const SIZED_SVECS = Dict{Int,Core.SimpleVector}() # (kept, so that their addresses are not reused)

function sized_svec(n::Int)
    sv = get!(SIZED_SVECS, n) do
        Core.svec(ntuple(_ -> nothing, n)...)
    end
    return UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), sv))
end

function struct_pieces(e::ObjectEmbedder, T::DataType, addr::UInt; n::Int=1)
    types = LLVM.LLVMType[]
    thunks = Function[]
    function add!(t, thunk)
        push!(types, t); push!(thunks, thunk)
    end
    add_bytes!(from, n) = n > 0 && add!(LLVM.ArrayType(LLVM.Int8Type(), n), g -> bytes_piece(from, n))
    function add_fields!(T, base)
        pos = 0 # offset within T
        for i in 1:fieldcount(T)
            off, ft = fieldoffset(T, i), fieldtype(T, i)
            add_bytes!(base + pos, off - pos)
            cut = field_cut(T, fieldname(T, i))
            (cut === :null || cut === :emptysvec) && Base.allocatedinline(ft) && sizeof(ft) == 0 && (cut = nothing) # (a field that holds nothing, as the `value` of a `OncePerProcess{Nothing}`, is not a reference)
            if cut === :null
                add!(LLVM.PointerType(), g -> nullptr())
                pos = off + sizeof(Ptr)
            elseif cut === :zero
                add!(LLVM.ArrayType(LLVM.Int8Type(), sizeof(ft)), g -> LLVM.ConstantDataArray(LLVM.Int8Type(), zeros(UInt8, sizeof(ft))))
                pos = off + sizeof(ft)
            elseif cut === :emptysvec
                add!(LLVM.PointerType(), g -> embed_ref!(e, EMPTY_SVEC[]))
                pos = off + sizeof(Ptr)
            elseif cut === :egalplan
                dt = unsafe_pointer_to_objref(Ptr{Cvoid}(addr))::DataType
                add!(LLVM.PointerType(), g -> egal_layout!(e, dt, addr))
                pos = off + sizeof(Ptr)
            elseif cut === :sizedsvec
                types_addr = unsafe_load(Ptr{UInt}(base + off))
                n = types_addr == 0 ? 0 : (check_readable(types_addr, 8); Int(unsafe_load(Ptr{Int}(types_addr))))
                (0 <= n <= 100_000 && types_addr % 8 == 0) || throw(EmbedFailure("a type whose fields are not a svec (not a type?), at $(string(addr, base = 16))"))
                add!(LLVM.PointerType(), g -> embed_ref!(e, sized_svec(n)))
                pos = off + sizeof(Ptr)
            elseif T <: Core.GenericMemoryRef && i == 1
                # a pointer into the data of the memory, which is the second field
                mem = unsafe_load(Ptr{UInt}(base + fieldoffset(T, 2)))
                check_readable(mem, 16)
                memdata = unsafe_load(Ptr{UInt}(mem + 8))
                p = unsafe_load(Ptr{UInt}(base + off))
                ET = T.parameters[2]
                if ET isa Union && Base.isbitsunion(ET)
                    add!(LLVM.Int64Type(), g -> i64(p)) # (for these it is the number of the element, and not a pointer)
                else
                    add!(LLVM.PointerType(), g -> embed_ref!(e, mem, 16 + Int(p) - Int(memdata)))
                end
                pos = off + sizeof(Ptr)
            elseif T <: Core.GenericMemoryRef && i == 2
                mem = unsafe_load(Ptr{UInt}(base + off))
                add!(LLVM.PointerType(), g -> embed_ref!(e, mem))
                pos = off + sizeof(Ptr)
            elseif ft <: Ptr && is_process_address(unsafe_load(Ptr{UInt}(base + off)))
                # An address in this process (of memory that a library allocated, of a function): it means nothing in the binary. Julia's own
                # compiled code (a package image) writes these as null, which is what is done here: what has the pointer made again
                # when it finds it null (a `Regex` compiles when its `regex` is null) goes on working, and what does not fails on the null.
                warn_dangling_pointer(T, fieldname(T, i))
                add!(LLVM.PointerType(), g -> nullptr())
                pos = off + sizeof(Ptr)
            elseif Base.allocatedinline(ft) && ft isa Union # a Union of types without pointers, and a byte that says which
                stop = i < fieldcount(T) ? Int(fieldoffset(T, i + 1)) : sizeof(T)
                add_bytes!(base + off, stop - off)
                pos = stop
            elseif Base.allocatedinline(ft)
                if Base.datatype_pointerfree(ft)
                    add_bytes!(base + off, sizeof(ft))
                else
                    add_fields!(ft, base + off)
                end
                pos = off + sizeof(ft)
            else # reference to another object
                r = unsafe_load(Ptr{UInt}(base + off))
                add!(LLVM.PointerType(), g -> embed_ref!(e, r))
                pos = off + sizeof(Ptr)
            end
        end
        add_bytes!(base + pos, sizeof(T) - pos)
    end
    for k in 0:n-1
        check_readable(addr + k * sizeof(T), sizeof(T))
        add_fields!(T, addr + k * sizeof(T))
    end
    isempty(types) && n > 0 && throw(EmbedFailure("no fields"))
    # values are created after the global, but the references they hold must exist before
    # it is (to compute the global's type), so they are created here and handed out later
    return types, g -> LLVM.Constant[thunk(g) for thunk in thunks]
end
