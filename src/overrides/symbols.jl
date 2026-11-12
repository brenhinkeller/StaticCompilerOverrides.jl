# Symbols that are made when the program runs: `Symbol("abc")` of a `String` that is not known when compiling, `Symbol("x", 1)`,
# `Symbol(uppercase(string(s)))`, ...
#
# Julia keeps all symbols in a table (in libjulia), so that there is one object for each name and `===` of symbols is a comparison of
# addresses. A program has no such table. The symbols that it has when it is compiled are copied into it, as any constant, so here:
#
# * the symbols that are in the binary are found in a list of them that is made when linking (`define_symbol_table!` in `runtime/constants.jl`),
#   sorted by name, which is searched first (a symbol that is in the binary is that object, so that `Symbol("abc") === :abc`);
# * a name that is not there is made into a symbol that is kept in a binary tree (as the table of Julia is, by the `left` and `right` of
#   the node, which the embedded symbols have as well), by its hash and then its name. Symbols are never freed (they are not made by the
#   collector's heap, and nothing in them refers to it). Memory: 40 bytes and the name, for each different name.
#
# A symbol is `{ left, right, hash, name, NUL }` (the object is at `left`; a header of 16 bytes with the type tag is before it). The hash is
# what `objectid` and so `hash` of a symbol is, so a `Dict` of symbols that was made when compiling and one that is made by the program agree.

# the list of the symbols of the binary, as { count, address of each symbol (sorted by name)... }, or null (the linker makes it if the program
# calls `static_symbol`; a weak reference, so that this still links without)
@inline embedded_symbols() = Base.llvmcall(("""
    @_static_symbols = extern_weak global i64
    define i64 @symbols() alwaysinline {
      ret i64 ptrtoint (ptr @_static_symbols to i64)
    }""", "symbols"), UInt, Tuple{})

# the text that `show` writes for the symbols of the binary that it is not `:name` for, as { count, (symbol, text as a C string)... } sorted by name
# (made by the linker if `show` of a symbol is in the program)
@inline embedded_symbol_texts() = Base.llvmcall(("""
    @_static_symbol_texts = extern_weak global i64
    define i64 @texts() alwaysinline {
      ret i64 ptrtoint (ptr @_static_symbol_texts to i64)
    }""", "texts"), UInt, Tuple{})

# the type tag of a symbol, as the code that is compiled has it
@generated static_symbol_tag() = :($(UInt(Runtime.object_tag(:a))))

const SYMBOL_NAME = 24 # the offset of the name in a symbol (after left, right and hash)

# how the name of the symbol at `sym` compares to the `n` bytes at `q`: -1, 0 or 1 (by the bytes, and the shorter first)
function compare_symbol_name(sym::UInt, q::Ptr{UInt8}, n::Int)
    name = Ptr{UInt8}(sym + SYMBOL_NAME)
    i = 0
    while i < n
        a = unsafe_load(name, i + 1)
        a == 0x00 && return -1 # (the name of the symbol is the shorter)
        b = unsafe_load(q, i + 1)
        a != b && return a < b ? -1 : 1
        i += 1
    end
    return unsafe_load(name, n + 1) == 0x00 ? 0 : 1
end

# the symbol of the binary with this name, or 0
function find_embedded_symbol(q::Ptr{UInt8}, n::Int)
    table = embedded_symbols()
    table == 0 && return UInt(0)
    lo = 1
    hi = Int(unsafe_load(Ptr{UInt}(table)))
    while lo <= hi
        mid = (lo + hi) >> 1
        sym = unsafe_load(Ptr{UInt}(table), mid + 1)
        c = compare_symbol_name(sym, q, n)
        c == 0 && return sym
        if c < 0
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return UInt(0)
end

# the hash of a name that is made here (the symbols of the binary have what Julia made: the hashes only have to agree among those made here)
symbol_hash(q::Ptr{UInt8}, n::Int) = murmur(i -> unsafe_load(Ptr{UInt64}(q + i)), i -> unsafe_load(q + i), n, 0xdeadbeef)

# the root of the tree of the symbols made by the program (the address of the first symbol, or 0)
const DYNAMIC_SYMBOLS = Ref{UInt}(0)

# a new symbol, outside of the heap that is collected (symbols are not freed), as { header (the type tag), left, right, hash, name, NUL }
function new_symbol(q::Ptr{UInt8}, n::Int, h::UInt64)
    mem = Ptr{UInt8}(calloc(1, 16 + SYMBOL_NAME + n + 1)) # (zero: no links, and the NUL)
    mem == C_NULL && throw(OutOfMemoryError())
    obj = UInt(mem) + 16
    unsafe_store!(Ptr{UInt}(obj - 8), static_symbol_tag())
    unsafe_store!(Ptr{UInt}(obj), h, 3)
    unsafe_copyto!(Ptr{UInt8}(obj + SYMBOL_NAME), q, n)
    return obj
end

# the symbol of the tree with this name, made if there is none
function dynamic_symbol(q::Ptr{UInt8}, n::Int)
    h = symbol_hash(q, n)
    slot = UInt(pointer_from_objref(DYNAMIC_SYMBOLS)) # (where the link to the next is: the root, and then `left` or `right` of a node)
    while true
        node = unsafe_load(Ptr{UInt}(slot))
        if node == 0
            sym = new_symbol(q, n, h)
            unsafe_store!(Ptr{UInt}(slot), sym)
            return sym
        end
        nh = unsafe_load(Ptr{UInt}(node), 3)
        c = h < nh ? -1 : h > nh ? 1 : -compare_symbol_name(node, q, n)
        c == 0 && return node
        slot = c < 0 ? node : node + 8
    end
end

"""
The symbol of `n` bytes at `q` (what `jl_symbol_n` does): the one of the binary if it has the name, or one that is made.
"""
function static_symbol(q::Ptr{UInt8}, n::Int)::Symbol
    n >= 0 || throw(ArgumentError("a Symbol of a negative length"))
    for i in 1:n
        # (the name of a symbol is a C string: its length is where the NUL is)
        unsafe_load(q, i) == 0x00 && throw(ArgumentError("a Symbol whose name has a NUL in it is not supported in standalone binaries"))
    end
    sym = find_embedded_symbol(q, n)
    sym == 0 && (sym = dynamic_symbol(q, n))
    return Base.unsafe_pointer_to_objref(Ptr{Cvoid}(sym))::Symbol
end

# (`Symbol` of a constant is a constant, as it is in Julia: that is what `foldable` says; the compiler evaluates the method of Base for it, which
# the overlay is a consistent replacement of, and not this one)
Base.@assume_effects :foldable @device_override function Core.Symbol(s::String)
    GC.@preserve s return static_symbol(Ptr{UInt8}(pointer(s)), sizeof(s))
end
@device_override function Core.Symbol(a::Vector{UInt8})
    GC.@preserve a return static_symbol(pointer(a), length(a))
end
@device_override function Base.Symbol(s::SubString{String})
    GC.@preserve s return static_symbol(Ptr{UInt8}(pointer(s)), sizeof(s))
end

# The C string that `show` writes for a symbol of the binary that is not `:name` (see `embedded_symbol_texts`), or 0
function symbol_text(s::Symbol)
    table = embedded_symbol_texts()
    table == 0 && return UInt(0)
    q = symbol_pointer(s)
    n = symbol_length(s)
    lo = 1
    hi = Int(unsafe_load(Ptr{UInt}(table)))
    while lo <= hi
        mid = (lo + hi) >> 1
        c = compare_symbol_name(unsafe_load(Ptr{UInt}(table), 2mid), q, n)
        c == 0 && return unsafe_load(Ptr{UInt}(table), 2mid + 1)
        if c < 0
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return UInt(0)
end

# whether the name of a symbol is a plain ASCII identifier (`Runtime.plain_symbol_name` is the same test, for the linker)
function symbol_is_plain(s::Symbol)
    p = symbol_pointer(s)
    n = symbol_length(s)
    n == 0 && return false
    for i in 1:n
        c = unsafe_load(p, i)
        isalpha = (UInt8('a') <= c <= UInt8('z')) || (UInt8('A') <= c <= UInt8('Z')) || c == UInt8('_')
        isother = (UInt8('0') <= c <= UInt8('9')) || c == UInt8('!')
        (isalpha || (i > 1 && isother)) || return false
    end
    return true
end

# A name that is certainly not an identifier or an operator, which `show` writes as `Symbol("...")`: it is empty, or has a space or a control
# character or a quote in it, or starts with a digit. (Of other names, whether they are operators is decided by the tables of the parser.)
function symbol_is_certainly_quoted(s::Symbol)
    p = symbol_pointer(s)
    n = symbol_length(s)
    n == 0 && return true
    c = unsafe_load(p, 1)
    (UInt8('0') <= c <= UInt8('9')) && return true
    for i in 1:n
        c = unsafe_load(p, i)
        (c <= 0x20 || c == 0x7f || c == UInt8('"')) && return true
    end
    return false
end

## `NamedTuple`s with a name that is not known when compiling
#
# `nt[name]`, `nt.name` and `get(nt, name, default)` with a `Symbol` that the program has when it runs (`FSCALES[scale]` of UnicodePlots: a table of the functions that a scale
# is made of, and a scale that a keyword says) is `getfield(nt, name)`, which for fields of different types has a type that depends on `name`, and is a call of the runtime that
# looks the field up and boxes it. One comparison of the name with each of the names gives each field its own type, and the result is the union of them, which is split when it is
# used (as the value of a `Union` is); for a name that is a constant the comparisons are folded, and for fields of one type they are selects. (Symbols are compared by address:
# one that was made by the program is the one that the binary has, see `static_symbol`.) The same is done for the `getfield` of a tuple with an index that is not known: `tuple_getindex`.
struct NoDefault end # (`default` of `namedtuple_field` when the name has to be there)
@generated function namedtuple_field(nt::NamedTuple{names}, name::Symbol, default) where {names}
    chain = default === NoDefault ? :(throw(FieldError(typeof(nt), name))) : :default
    for k in length(names):-1:1
        chain = :(name === $(QuoteNode(names[k])) ? getfield(nt, $k) : $chain)
    end
    return chain
end
namedtuple_field(nt::NamedTuple, name::Symbol) = namedtuple_field(nt, name, NoDefault())

@device_override @inline Base.getindex(nt::NamedTuple, name::Symbol) = namedtuple_field(nt, name)
@device_override @inline Base.getproperty(nt::NamedTuple, name::Symbol) = namedtuple_field(nt, name)
@device_override @inline Base.get(nt::NamedTuple, name::Symbol, default) = namedtuple_field(nt, name, default)
