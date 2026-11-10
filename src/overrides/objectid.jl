# `objectid`, which `hash` uses for what has no `hash` method of its own (a struct as the key of a `Dict`).
#
# In Julia it is `jl_object_id`, which looks at the type of an object when the program is run, and mixes
# the contents of the object, field by field (`immut_id_` in `src/builtins.c`). That is a call of libjulia.
# The types of what is hashed are known when compiling (and a call of an abstract type, which is not, is
# left as it was), so here the same is written out for each type, with the same hash functions: the result is
# the same number as in Julia (so that a `Dict` that was made when compiling, and is in the binary, can be
# looked up in), which the tests check.

## the hash functions of `src/support/hashing.c` and `MurmurHash3.c` (64 bit)

@inline function int32hash(a::UInt32)
    a = (a + 0x7ed55d16) + (a << 12)
    a = (a ⊻ 0xc761c23c) ⊻ (a >> 19)
    a = (a + 0x165667b1) + (a << 5)
    a = (a + 0xd3a2646c) ⊻ (a << 9)
    a = (a + 0xfd7046c5) + (a << 3)
    a = (a ⊻ 0xb55a4f09) ⊻ (a >> 16)
    return a
end

@inline function int64hash(key::UInt64)
    key = (~key) + (key << 21)
    key = key ⊻ (key >> 24)
    key = (key + (key << 3)) + (key << 8)
    key = key ⊻ (key >> 14)
    key = (key + (key << 2)) + (key << 4)
    key = key ⊻ (key >> 28)
    key = key + (key << 31)
    return key
end

@inline bitmix(a::UInt64, b::UInt64) = int64hash(a ⊻ bswap(b))

@inline function fmix64(k::UInt64)
    k ⊻= k >> 33
    k *= 0xff51afd7ed558ccd
    k ⊻= k >> 33
    k *= 0xc4ceb9fe1a85ec53
    k ⊻= k >> 33
    return k
end

@inline rotl64(x::UInt64, r) = (x << r) | (x >> (64 - r))

# `MurmurHash3_x64_128` of `len` bytes, of which `u64(i)` is the 8 at the offset `i` (little endian) and
# `u8(i)` the one at `i`: the second of its two numbers, as `memhash_seed` returns
@inline function murmur(u64, u8, len::Int, seed::UInt32)
    c1 = 0x87c37b91114253d5
    c2 = 0x4cf5ad432745937f
    h1 = UInt64(seed)
    h2 = UInt64(seed)
    nblocks = len ÷ 16
    for i in 0:nblocks-1
        k1 = u64(16i)
        k2 = u64(16i + 8)
        k1 *= c1; k1 = rotl64(k1, 31); k1 *= c2; h1 ⊻= k1
        h1 = rotl64(h1, 27); h1 += h2; h1 = h1 * 5 + 0x52dce729
        k2 *= c2; k2 = rotl64(k2, 33); k2 *= c1; h2 ⊻= k2
        h2 = rotl64(h2, 31); h2 += h1; h2 = h2 * 5 + 0x38495ab5
    end
    tail = 16 * nblocks
    rest = len & 15
    k1 = UInt64(0)
    k2 = UInt64(0)
    for j in 0:min(rest, 8)-1 # (the bytes 0 to 7 of the tail)
        k1 ⊻= UInt64(u8(tail + j)) << (8j)
    end
    for j in 0:rest-9 # (and the bytes 8 to 14)
        k2 ⊻= UInt64(u8(tail + 8 + j)) << (8j)
    end
    if rest > 8
        k2 *= c2; k2 = rotl64(k2, 33); k2 *= c1; h2 ⊻= k2
    end
    if rest > 0
        k1 *= c1; k1 = rotl64(k1, 31); k1 *= c2; h1 ⊻= k1
    end
    h1 ⊻= len % UInt64; h2 ⊻= len % UInt64
    h1 += h2; h2 += h1
    h1 = fmix64(h1); h2 = fmix64(h2)
    h1 += h2; h2 += h1
    return h2
end

# of the bytes of a string, as `jl_object_id` of a `String`
@inline function memhash_string(s::String, seed::UInt32)
    GC.@preserve s begin
        p = pointer(s)
        return murmur(i -> unsafe_load(Ptr{UInt64}(p + i)), i -> unsafe_load(p + i), sizeof(s), seed)
    end
end

# of the bytes of an `isbits` value (a tuple of its bytes, which indexing needs: no memory)
@inline function memhash_bits(t::NTuple{N,UInt8}, seed::UInt32) where {N}
    u8(i) = @inbounds t[i + 1]
    u64(i) = reduce(|, (UInt64(u8(i + j)) << (8j) for j in 0:7))
    return murmur(u64, u8, N, seed)
end

## the contents of a value (`bits_hash` and `immut_id_` of builtins.c)

# of the value `x`, whose bytes are all of it: `bits_hash`
@inline function bits_hash(x::T) where {T}
    sz = sizeof(T)
    sz == 1 && return UInt64(int32hash(Int32(reinterpret(Int8, x)) % UInt32))
    sz == 2 && return UInt64(int32hash(UInt32(reinterpret(UInt16, x))))
    sz == 4 && return UInt64(int32hash(reinterpret(UInt32, x)))
    sz == 8 && return int64hash(reinterpret(UInt64, x))
    return memhash_bits(reinterpret(NTuple{sz,UInt8}, x), 0xcafe8881)
end

# whether the contents of a type are all in its bytes, and compared as they are: no padding, no references, and no
# Union (with the byte that says which type it holds)
function bytes_are_value(T::DataType)
    isconcretetype(T) && !Base.datatype_haspadding(T) || return false
    for i in 1:fieldcount(T)
        ft = fieldtype(T, i)
        (ft isa DataType && Base.allocatedinline(ft) && bytes_are_value(ft)) || return false
    end
    return true
end

# `immut_id_(T, x, h)`, for `x` of the concrete, immutable type `T`, unrolled for it
@generated function immutable_id(x::T, h::UInt64) where {T}
    sz = sizeof(T)
    sz == 0 && return :(~h)
    if fieldcount(T) == 0
        # (a primitive type with bits that aren't part of the value is hashed on the value bits only)
        Base.datatype_haspadding(T) && return :(ccall(:jl_object_id, UInt, (Any,), x))
        return :(bits_hash(x) ⊻ h)
    end
    bytes_are_value(T) && return :(bits_hash(x) ⊻ h)
    body = Expr(:block)
    for i in 1:fieldcount(T)
        ft = fieldtype(T, i)
        u = if !Base.allocatedinline(ft)
            # a reference: the object id of what it refers to, which is of the type that the field has, or of one of
            # the types of a Union; for another abstract type that is not known when compiling
            ref = if ft isa Union
                chain = :(ccall(:jl_object_id, UInt, (Any,), v))
                for C in reverse(Base.uniontypes(ft))
                    isconcretetype(C) && (chain = :(v isa $C ? static_objectid(v::$C) : $chain))
                end
                chain
            elseif isconcretetype(ft)
                :(static_objectid(v))
            else
                :(ccall(:jl_object_id, UInt, (Any,), v))
            end
            :(isdefined(x, $i) ? (let v = getfield(x, $i); $ref; end) : UInt64(0))
        elseif ft isa Union
            # (the types of a Union that is stored inline: the one that the value has is the one that was stored)
            chain = :(UInt64(0))
            for C in reverse(Base.uniontypes(ft))
                chain = :(v isa $C ? immutable_id(v::$C, UInt64(0)) : $chain)
            end
            :(let v = getfield(x, $i); $chain; end)
        else
            :(isdefined(x, $i) ? immutable_id(getfield(x, $i), UInt64(0)) : UInt64(0)) # (a struct that is stored inline)
        end
        push!(body.args, :(h = bitmix(h, $u)))
    end
    push!(body.args, :h)
    return body
end

# `objectid`, from the type of `x`: what `jl_object_id` does with it
@generated function static_objectid(x::T) where {T}
    fallback = :(ccall(:jl_object_id, UInt, (Any,), x))
    # the object id of a `DataType` is its `hash` (which is made from its name and parameters, and is copied into the binary with it)
    T === DataType && return :(UInt(getfield(x, :hash) % UInt32))
    (isconcretetype(T) && T !== DataType && T !== Module && T !== Core.TypeName && T !== Core.SimpleVector &&
        T !== Symbol) || return fallback
    T === String && return :(memhash_string(x, 0xedc3b677))
    ismutabletype(T) && return :(int64hash(UInt64(UInt(pointer_from_objref(x))))) # the address
    return :(immutable_id(x, $(UInt64(getfield(T, :hash) % UInt32))))
end
@device_override Base.objectid(x) = static_objectid(x)

# `T == S` of types is a call of libjulia (`jl_types_equal`). Two types are equal if each is a subtype of the other: for concrete types,
# which there is one object of each, that is `===`, and that is all that has to be looked at when both are concrete. (Types that are not,
# a `Union` or an abstract type with parameters, are compared by `<:`: the table of `<:` in `runtime/types.jl`.)
@device_override function Base.:(==)(a::Type, b::Type)
    a === b && return true
    (a isa DataType && b isa DataType && isconcretetype(a) && isconcretetype(b)) && return false
    return (a <: b) & (b <: a)
end

# `hash` of a type is made from `jl_type_hash`, which for a `DataType` is its `hash` field, as `objectid` is (above). The other types (a
# `Union`, a `UnionAll`) have it computed from what they are made of, which is libjulia's, and so is as it was.
#
# OPEN: a program that hashes one of those is refused when compiling (`jl_type_hash` is a call that needs libjulia). It is reached only when the code that hashes is not folded
# by the compiler: Distributions' `MvNormal` with a diagonal covariance does it under `--code-coverage` (which stops Julia from inlining and constant-folding the code of
# packages), and not otherwise; see `test/packages/distributions.jl`. Computing the hash of a `Union` or a `UnionAll` here (from the hashes of its parts, as libjulia does) would end it.
@device_override Base._jl_type_hash(T::Type) = T isa DataType ? UInt(getfield(T, :hash) % UInt32) : ccall(:jl_type_hash, UInt, (Any,), T)
