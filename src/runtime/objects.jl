# The objects of the process that compiles, as they are in memory: their type tags, what a type object, a symbol, a `svec` is, how far an object extends, which fields of a type are
# not copied, and why some objects can't be copied at all. What `embedder.jl` and `constants.jl` use to put them into a binary.

# The type tag of the objects of a type, as Julia writes it before them (in this process, where the
# code that is compiled has been inferred, so the tags that it compares with are these as well)
object_tag(x) = Int64(unsafe_load(Ptr{UInt}(UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), x)) - 8)) & ~UInt(15))

# the type that objects with the tag `tag` have (what `type_tag` is the inverse of), or `nothing` if it isn't one
function tag_type(tag::UInt)
    if tag < (64 << 4)
        p = unsafe_load(cglobal(:jl_small_typeof, Ptr{Ptr{Cvoid}}), (tag >> 3) + 1)
        return p == C_NULL ? nothing : unsafe_pointer_to_objref(p)
    end
    object_type(tag) === DataType || return nothing
    return unsafe_pointer_to_objref(Ptr{Cvoid}(tag))
end

# ---------------------------------------------------------------------------------------
# Constants: compiled code refers to some Julia objects by address (`inttoptr`), which is
# meaningless in a standalone binary (string literals, `const` arrays and `Ref`s, the empty
# `Memory` singletons, ...). We copy the objects we can reproduce into globals of the module,
# following references to other objects, and point the code at those instead. Objects that
# contain things we can't reproduce (types, symbols, functions, ...) are left alone, to be
# reported by the pointer check.
#
# The globals have no type-tag header, since there is no type object to tag them with.

# A word of memory at `addr`, or `nothing` if it is not readable. The kernel checks the
# address when we ask it to copy the word into a pipe, so we don't crash on a bad pointer.
const PIPE_FDS = Cint[-1, -1]

function safe_load(addr::UInt)::Union{UInt,Nothing}
    PIPE_FDS[1] < 0 && (ccall(:pipe, Cint, (Ptr{Cint},), PIPE_FDS) == 0 || error("pipe failed"))
    n = ccall(:write, Cssize_t, (Cint, UInt, Csize_t), PIPE_FDS[2], addr, 8)
    n == 8 || return nothing
    out = Ref{UInt}(0)
    ccall(:read, Cssize_t, (Cint, Ptr{UInt}, Csize_t), PIPE_FDS[1], out, 8) == 8 || return nothing
    return out[]
end

# throw `EmbedFailure` unless the `n` bytes at `addr` can be read
function check_readable(addr::UInt, n::Integer)
    n >= 0 && n < (1 << 28) || throw(EmbedFailure("implausible size"))
    n == 0 && return
    for off in 0:4096:(n - 1)
        safe_load(addr + off) === nothing && throw(EmbedFailure("unreadable memory"))
    end
    safe_load(addr + max(n - 8, 0)) === nothing && throw(EmbedFailure("unreadable memory"))
    return
end

const DATATYPE_TAG = Ref{UInt}(0) # the tag of `DataType` objects

const TYPENAME_TAG = Ref{UInt}(0) # the tag of `TypeName` objects

const SVEC_TAG = Ref{UInt}(0) # the tag of `svec`s

# the type of the Julia object at `addr`, from its type tag, or `nothing` if it doesn't look
# like an object.
# The types of the objects that are types (the last is `Union{}`). In Julia 1.14 `Type{T}` is itself an object, of the type `Core.TypeEq`
# (and `Core.TypeEgal`), that has the type `T` in it.
const TYPE_OBJECT_KINDS = (DataType, UnionAll, Union, Core.TypeofBottom,
                           (isdefined(Core, :TypeEq) ? (Core.TypeEq, Core.TypeEgal) : ())...)

function object_type(addr::UInt)
    # All Julia objects are 16-byte aligned, which rules out many addresses that are not objects: in
    # particular the data of strings and arrays, which is 8 bytes after the start of the object. The
    # exception is symbols, which are 8-byte aligned (see `is_symbol` for checking one).
    addr >= 0x10000 && addr % 8 == 0 || return nothing
    DATATYPE_TAG[] == 0 && (DATATYPE_TAG[] = unsafe_load(Ptr{UInt}(UInt(pointer_from_objref(typeof(Int))) - 8)) & ~UInt(15))
    word = safe_load(addr - 8)
    word === nothing && return nothing
    tag = word & ~UInt(15)
    ptr = if tag < (64 << 4)
        unsafe_load(cglobal(:jl_small_typeof, Ptr{Ptr{Cvoid}}), (tag >> 3) + 1)
    else
        Ptr{Cvoid}(tag)
    end
    ptr == C_NULL && return nothing
    # the tag must point at a `DataType`
    typetag = safe_load(UInt(ptr) - 8)
    (typetag === nothing || typetag & ~UInt(15) != DATATYPE_TAG[]) && return nothing
    # (a word before an address that is a type tag is not enough: it may be a field that holds the type `DataType`, with the next
    # field after it, which is not a type. Asking Julia anything about that, as `<:` does, crashes it. So look at what a `DataType`
    # has: its name is a `TypeName`, and its supertype a `DataType`.)
    is_tagged(p, tag) = (w = safe_load(p - 8); w !== nothing && w & ~UInt(15) == tag)
    TYPENAME_TAG[] == 0 && (TYPENAME_TAG[] = unsafe_load(Ptr{UInt}(UInt(pointer_from_objref(typeof(Int).name)) - 8)) & ~UInt(15))
    name = safe_load(UInt(ptr))
    super = safe_load(UInt(ptr) + 8)
    (name === nothing || super === nothing || name % 16 != 0 || super % 16 != 0) && return nothing
    is_tagged(name, TYPENAME_TAG[]) && is_tagged(super, DATATYPE_TAG[]) || return nothing
    # (and the lists of its parameters and of the types of its fields are `svec`s: asking Julia for the fields of a type, which
    # `isconcretetype` and what follows do, reads the length of the list that the word is at)
    SVEC_TAG[] == 0 && (SVEC_TAG[] = unsafe_load(Ptr{UInt}(UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), Core.svec(1))) - 8)) & ~UInt(15))
    parameters = safe_load(UInt(ptr) + fieldoffset(DataType, 3))
    types = safe_load(UInt(ptr) + fieldoffset(DataType, 4))
    (parameters === nothing || types === nothing) && return nothing
    (parameters % 16 == 0 && is_tagged(parameters, SVEC_TAG[])) || return nothing
    (types == 0 || (types % 16 == 0 && is_tagged(types, SVEC_TAG[]))) || return nothing # (null until the fields of the type are looked up)
    T = unsafe_pointer_to_objref(ptr)
    T isa DataType && isconcretetype(T) || return nothing
    # the objects that are types (`typeof(Int)` is `DataType`) are objects as well, those of these kinds (the last is `Union{}`)
    (T <: Type) && !(T in TYPE_OBJECT_KINDS) && return nothing
    addr % 16 == 0 && return T
    # (the one instance of a type that has no fields, which has no contents, is allocated where the data of an object would be, 8 bytes in
    # a cell that is 16 aligned: it is the `instance` of its type)
    Base.issingletontype(T) && isdefined(T, :instance) &&
        UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), T.instance)) == addr && return T
    return T === Symbol && is_symbol(addr) ? T : nothing
end

# Is the object at `addr`, of which the tag says that it is a symbol (and which is not aligned as
# other objects), one? A symbol is { left, right, hash, name }, where `left` and `right` are links
# to other symbols (or null), and the name is a C string, which we check to be reasonable, as
# the right-looking tag of a symbol may also be the length of a string.
function is_symbol(addr::UInt)
    for offset in (0, 8)
        link = safe_load(addr + offset)
        link === nothing && return false
        link == 0 && continue
        link % 8 == 0 && link >= 0x10000 || return false
        tag = safe_load(link - 8)
        tag === nothing && return false
        tag & ~UInt(15) == symbol_tag() || return false
    end
    safe_load(addr + 16) === nothing && return false
    # the name: at least one character, up to its NUL, of the characters that are fine in a name
    for i in 0:255
        word = safe_load(addr + 24 + 8 * (i ÷ 8))
        word === nothing && return false
        byte = UInt8((word >> (8 * (i % 8))) & 0xff)
        byte == 0x00 && return i > 0
        byte >= 0x20 && byte != 0x7f || return false
    end
    return false
end

const SYMBOL_TAG = Ref{UInt}(0) # the tag of symbols

symbol_tag() = (SYMBOL_TAG[] == 0 && (SYMBOL_TAG[] = unsafe_load(Ptr{UInt}(UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), :a)) - 8)) & ~UInt(15)); SYMBOL_TAG[])

# Tables whose places depend on addresses: a `Dict` (or a `Set`) of keys that `hash` by `objectid`, which for a mutable object is its address, and an
# `IdDict`, which is made with the addresses of the keys, whatever they are. The copy of such a table in the binary has the keys at other
# addresses, so what it looks up is not found, and no error says so. Such a table is refused.

# whether `objectid(x)` is made from an address: `x` is a mutable object, or has one in a field (as `objectid` of the fields of an immutable
# struct is the `objectid` of what they refer to)
function objectid_by_address(x, depth::Int = 0)
    T = typeof(x)
    # (a type, a module, a symbol and a string have their own hashes, which are not those of their addresses)
    T <: Union{DataType, Module, Core.TypeName, Symbol, String, Core.SimpleVector, Union, UnionAll} && return false
    ismutabletype(T) && return true
    (depth > 8 || isbitstype(T)) && return false
    for i in 1:fieldcount(T)
        isdefined(x, i) && objectid_by_address(getfield(x, i), depth + 1) && return true
    end
    return false
end

# whether `hash` of the key is made with its `objectid` (the fallback method of Base)
function hash_is_objectid(x)
    m = Base.invokelatest(which, hash, Tuple{typeof(x), UInt})
    return m.sig == Tuple{typeof(hash), Any, UInt}
end

# why the table at `addr` of the type `T` can't be copied, or `nothing`
function address_hashed_reason(T::DataType, addr::UInt)
    (T <: Dict || T <: IdDict) || return nothing
    d = unsafe_pointer_to_objref(Ptr{Cvoid}(addr))
    isempty(d) && return nothing
    if d isa IdDict
        return string("an `IdDict` that has keys (`", T, "`), whose places in the table are from the addresses of the keys, which are not those of the binary: ",
                      "make it when the program runs, or use a `Dict`")
    end
    for k in keys(d)
        if objectid_by_address(k) && hash_is_objectid(k)
            return string("a `", T, "` whose keys of the type `", typeof(k), "` are hashed by their addresses (the `hash` of `Base` for a type that has no method of its own is ",
                          "its `objectid`), which are not those of the binary, so a lookup would not find them: define `Base.hash(::", typeof(k), ", ::UInt)` (and `==`), ",
                          "or make the table when the program runs")
        end
    end
    return nothing
end

# The global variables that are not `const` of Julia itself (`stdout`, `stderr` and `stdin`, which are the streams of libuv of the process that compiles) are
# its own state and are not copied into a binary: a program that uses them has its own (see `STDOUT`).
function runtime_binding_reason(T::DataType, addr::UInt)
    T === Core.Binding || return nothing
    ref = unsafe_pointer_to_objref(Ptr{Cvoid}(addr)).globalref
    ref isa GlobalRef && (ref.mod === Base || ref.mod === Core) || return nothing
    return string("the global variable `", ref.mod, ".", ref.name, "`, which is part of the state of the Julia that compiles (for the standard streams: use `STDOUT`, `STDERR` and `STDIN`)")
end

# the fields of a struct, in memory order, with padding copied as is
# Fields of the objects that are types, which are not reproduced, as they are the runtime's own and refer to
# most of what there is: a type refers to the types of its fields (`types`), a type name to the types
# that were made of it (`cache`), ... Code that reads these in a program that is run gets null, or an
# empty list, instead.
#
# The same for what a program that has a type only to tell the type of an object from another (its tag, or an `isa`
# that is made at compile time) does not need: the supertype, the wrapper and the names of the fields. They refer to
# the supertypes (each with a name, a wrapper, ...), and so most of the objects of a small program are there for
# them: with these cut, `println(42)` has 4.5 kB of data instead of 12 kB. What the type is called (`nameof`), its
# parameters, and the tests of types are not affected; but `supertype(T)`, `fieldnames(T)` and `T.name.wrapper` of a type
# that is only known when the program runs are not available in a program (they were not before: calls like these
# are dynamic).
const EMPTY_SVEC = Ref{UInt}(0) # the address of the empty `svec()`

function field_cut(T::Type, name)
    EMPTY_SVEC[] == 0 && (EMPTY_SVEC[] = UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), Core.svec())))
    if T === DataType
        name === :types && return :sizedsvec
        name === :super && return :null # (the chain of supertypes, which a program only has to have if it asks for them)
        return name === :layout ? :egalplan : nothing
    elseif T === Core.Binding
        # A global variable that is not a `const` is read and written as the `value` of its binding (the code has the address of that field). The binding is
        # copied with the value that it has when compiling, as a cell that the program can change; what it says of where it is (its module, the lists of
        # what depends on it, the partitions that say what it is) is the runtime's own and refers to modules, which are not in the binary.
        name in (:globalref, :partitions, :backedges, :owner, :ty) && return :null
    elseif T <: Base.OncePerProcess
        # A value that is made when the program first asks for it, and whether that has been done: the program starts as a package image does (Julia
        # sets these back when it saves one), so what the initializer does (setting up a library) is done by the program, and not taken from this process.
        name === :value && return :null
        name === :state && return :zero
        name === :lock && return :null # (a lock has a task and a condition in it: the program has one task, and the methods of `lock` here do nothing)
    elseif T === Core.TypeName
        name === :wrapper && return :null # (the `UnionAll` of the type, with its `TypeVar`s)
        name === :names && return :emptysvec # (the names of the fields)
        name in (:module, :atomicfields, :constfields, :partial, :Typeofwrapper, :mt) && return :null
        name in (:cache, :linearcache) && return :emptysvec
    end
    return nothing
end

# (`n` structs of the type, one after the other, as the elements of a `Memory` are)
# whether a pointer is an address in this process, as opposed to a number that stands for something (MPICH's `MPI_STATUS_IGNORE` is 1, and `MPI_IN_PLACE` is -1): the
# addresses of memory are not small numbers, and not above the 48 bits of the address space
is_process_address(p::UInt) = UInt(0x10000) <= p < (UInt(1) << 48)

const DANGLING_POINTER_WARNED = Set{Tuple{Any,Symbol}}()

# (a `Regex` and a `LazyLibrary` make theirs again when the program runs, so that those are not worth a warning)
function warn_dangling_pointer(T, name::Symbol)
    (T <: Regex && name === :regex) && return
    (T <: Libdl.LazyLibrary && name === :handle) && return
    (T, name) in DANGLING_POINTER_WARNED && return
    push!(DANGLING_POINTER_WARNED, (T, name))
    @warn "The field `$name` of a constant of the type `$T` holds an address of this process, which means nothing in the program: it is null there." maxlog = 1
    return
end

# The object that `addr` points into, with the offset of `addr` in it: constants can point
# at fields of an object (e.g., the data of a string)
function object_extent(T::DataType, base::UInt)
    T === String && return 8 + unsafe_load(Ptr{Int}(base)) + 1
    # a symbol is { left, right, hash, name, NUL }: the code reads its hash (`objectid`, so `hash` and a `Dict` of symbols) and its
    # name (`string`) with an address in it, that of the field
    T === Symbol && return 24 + Int(ccall(:strlen, Csize_t, (Ptr{UInt8},), Ptr{UInt8}(base + 24))) + 1
    if T <: Core.GenericMemory
        ET = eltype(T)
        len = unsafe_load(Ptr{Int}(base))
        # the header and the elements, which are inline (and boxed elements are pointers)
        return 16 + len * (isbitstype(ET) ? Base.aligned_sizeof(ET) : sizeof(Ptr))
    end
    return try Core.sizeof(T) catch; 0 end # no definite size: not something we embed
end

# The objects that `addr` may point into, as (base address, offset of `addr` in it): constants can
# point at fields of an object (e.g., the data of a string). Whether there is an object at an
# address is judged by its type tag, the word before it, and an address that is not that of an
# object may look like one by chance. So there can be several candidates, only one of which is
# right, and the caller needs to try them in order: the one closest to `addr` first, since a
# false one is usually further away. (The false ones that are tried usually fail to be
# embedded: their contents are not valid.)
# how far before an address the object that it is in can start: a field of a struct of many fields (a `SphericalHe` is 392 bytes)
const MAX_INTERIOR = 2048

function find_objects(addr::UInt)
    candidates = Tuple{UInt,Int}[]
    # an address that is the start of an object (a type, say) is that object: an object that has it in its data, nearer or farther, would
    # be another that something that looks like one found (the tag of the next, or a number in a field)
    addr % 16 == 0 && object_type(addr) !== nothing && return [(addr, 0)]
    for delta in Int(addr % 8):8:MAX_INTERIOR # (objects are aligned: `addr` may be in the middle of the data of one)
        base = addr - delta
        T = object_type(base)
        T === nothing && continue
        delta <= max(object_extent(T, base), 8) || continue
        push!(candidates, (base, delta))
    end
    return candidates
end
