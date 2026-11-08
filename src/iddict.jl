# `IdDict`, without libjulia.
#
# An `IdDict` keeps its keys and values in a `Memory{Any}` (a key, then its value), and Base looks in that table, adds to it, and
# removes from it with `jl_eqtable_*`, functions of libjulia. Here the same table is kept with Julia code (linear probing, with the
# hash of `objectid`, as the docstring of `IdDict` says): the struct is Base's own, and what is not written here (iteration, `length`,
# `copy`, ...) is Base's. This is what `deepcopy` uses.
#
# The hash: the address of a mutable object (which is what `objectid` is, too), and one number for everything else. Keys are
# also looked at as `Any` when the table is made larger, and the types they have then are not known when compiling, so this
# can't use the types (`objectid` of an immutable looks at its fields, one type at a time): a table with many keys that are not
# mutable (an `IdDict{Int,...}`) is slow, but not wrong.
eq_hash(key) = ismutable(key) ? int64hash(UInt64(UInt(pointer_from_objref(key)))) : UInt64(0x9e3779b97f4a7c15)

# A slot of keys that has not been assigned is empty, and one that holds `secret_table_token` has had its key removed.

const EQ_DELETED = Base.secret_table_token

# the index in `ht` of the key `key` (the value is at the next one), or 0 when it is not there
function eq_find(ht::Memory{Any}, key)
    slots = length(ht) >> 1 # (a power of two)
    i = (eq_hash(key) % Int) & (slots - 1)
    for _ in 1:slots
        k = 2i + 1
        isassigned(ht, k) || return 0
        ht[k] === key && return k
        i = (i + 1) & (slots - 1)
    end
    return 0
end

# add `key` => `val` to a table that has room (the key is not in it), and where the key goes
function eq_insert!(ht::Memory{Any}, key, val)
    slots = length(ht) >> 1
    i = (eq_hash(key) % Int) & (slots - 1)
    while true
        k = 2i + 1
        if !isassigned(ht, k) || ht[k] === EQ_DELETED
            ht[k] = key
            ht[k+1] = val
            return nothing
        end
        i = (i + 1) & (slots - 1)
    end
end

# a table of `slots` (a power of two, more than there are keys) with the keys that are in `ht`
function eq_rehash(ht::Memory{Any}, slots::Int)
    new = Memory{Any}(undef, 2 * slots)
    for k in 1:2:length(ht)
        (isassigned(ht, k) && ht[k] !== EQ_DELETED) || continue
        eq_insert!(new, ht[k], ht[k+1])
    end
    return new
end

eq_slots(n::Int) = max(16, 1 << (8 * sizeof(Int) - leading_zeros(max(n, 1) - 1)))

@device_override function Base.rehash!(d::IdDict, newsz::Integer = length(d.ht) % UInt)
    d.ht = eq_rehash(d.ht, eq_slots(max(Int(newsz) >> 1, 2 * d.count)))
    d.ndel = 0
    return d
end

@device_override function Base.setindex!(d::IdDict{K,V}, val, key) where {K,V}
    key isa K || throw(Base.KeyTypeError(K, key))
    val isa V || (val = convert(V, val)::V)
    k = eq_find(d.ht, key)
    if k != 0
        d.ht[k+1] = val
        return d
    end
    slots = length(d.ht) >> 1
    if 4 * (d.count + d.ndel + 1) > 3 * slots # (cleaning out the removed ones, and growing if it is full of keys)
        d.ht = eq_rehash(d.ht, eq_slots(4 * (d.count + 1) ÷ 3 + 1))
        d.ndel = 0
    end
    eq_insert!(d.ht, key, val)
    d.count += 1
    return d
end

@device_override function Base.get(d::IdDict{K,V}, key, default) where {K,V}
    k = eq_find(d.ht, key)
    return k == 0 ? default : d.ht[k+1]::V
end

@device_override function Base.getindex(d::IdDict{K,V}, key) where {K,V}
    k = eq_find(d.ht, key)
    k == 0 && throw(KeyError(key))
    return d.ht[k+1]::V
end

@device_override function Base.get(default::Base.Callable, d::IdDict{K,V}, key) where {K,V}
    k = eq_find(d.ht, key)
    return k == 0 ? default() : d.ht[k+1]::V
end

@device_override function Base.get!(d::IdDict{K,V}, key, default) where {K,V}
    k = eq_find(d.ht, key)
    k != 0 && return d.ht[k+1]::V
    val = isa(default, V) ? default : convert(V, default)::V
    setindex!(d, val, key)
    return val
end

@device_override function Base.get!(default::Base.Callable, d::IdDict{K,V}, key) where {K,V}
    k = eq_find(d.ht, key)
    k != 0 && return d.ht[k+1]::V
    val = default()
    isa(val, V) || (val = convert(V, val)::V)
    setindex!(d, val, key)
    return val
end

@device_override function Base.pop!(d::IdDict{K,V}, key, default) where {K,V}
    k = eq_find(d.ht, key)
    k == 0 && return default
    val = d.ht[k+1]::V
    d.ht[k] = EQ_DELETED
    d.ht[k+1] = nothing
    d.count -= 1
    d.ndel += 1
    return val
end

# (the iteration of Base: the index of the key slot after `i`, or -1)
@device_override function Base._oidd_nextind(a::Memory{Any}, i)
    k = Int(i) + 1
    while k < length(a)
        isassigned(a, k) && a[k] !== EQ_DELETED && return k - 1
        k += 2
    end
    return -1
end
