# Overrides of methods of Base (and the standard libraries) that can be written in a way that
# compiles statically, with the same behavior.

# `print_to_string(xs...)`, which `string`, error messages and `sprint`-like helpers use, loops
# over its arguments as `for i in 1:nfields(xs); print(s, xs[i]); end`. When the arguments have
# different types, the type of `xs[i]` depends on `i`, which is not known when compiling, so every
# call becomes a dynamic dispatch. Recursing over the tuple gives each element its own type.
@device_override function Base.print_to_string(xs...)
    isempty(xs) && return ""
    s = IOBuffer(sizehint = sizehint_sum(xs...))
    print_each(BufIO(s), xs...) # (a `BufIO`: the methods of `show` in `show.jl` are for it)
    return Base.takestring!(s)
end

sizehint_sum() = 0
sizehint_sum(x, xs...) = Base._str_sizehint(x) + sizehint_sum(xs...)

print_each(s) = nothing
function print_each(s, x, xs...)
    print(s, x)
    return print_each(s, xs...)
end

# `[x, y, ...]` (`Base.vect`) fills the vector with a loop over its arguments, `X[i]`. For arguments of different
# types (an `Any[1, "a"]`) the type of that depends on `i`, which is not known when compiling, so it is a
# dynamic call. Recursing over the arguments gives each its own type.
@device_override function Base.vect(X...)
    isempty(X) && return Vector{Any}()
    a = Vector{Base.promote_typeof(X...)}(undef, length(X))
    vect_fill!(a, 1, X...)
    return a
end
# the same for `Any[x, y, ...]`, which is `getindex(Any, x, y, ...)` (only for `Any`, where the types of the
# elements differ; for the others, Base's method is the one that compiles well)
@device_override function Base.getindex(::Type{Any}, vals...)
    a = Vector{Any}(undef, length(vals))
    vect_fill!(a, 1, vals...)
    return a
end
vect_fill!(a, i) = a
function vect_fill!(a, i, x, xs...)
    @inbounds a[i] = x
    return vect_fill!(a, i + 1, xs...)
end

# Locks. A compiled program has one thread and no tasks, so a lock can never be contended: taking
# one has no effect. (Without this, `lock` pulls in the whole task scheduler, for the case in
# which another task holds the lock.) Note that unlocking a lock that is not held is not an error.
@device_override Base.lock(::ReentrantLock) = nothing
@device_override Base.unlock(::ReentrantLock) = nothing
@device_override Base.trylock(::ReentrantLock) = true
@device_override Base.islocked(::ReentrantLock) = false

# Cancellation (Julia 1.14). Whether an operation has been cancelled is looked up from the scope of
# the current task, which compiled programs don't have: there is never a cancellation token. (This
# is checked by operations that may block or allocate, so without it much of Base needs the scheduler.)
@static if isdefined(Base, :default_cancel_token)
    @device_override Base.default_cancel_token() = nothing
end

# The slow path of a cancellation point (`@cancel_check`), which is only reached when it reports a pending
# yield or cancellation. Without a source it can only be a request to let another task run: there are none.
@static if isdefined(Base, :handle_cancellation!)
    @device_override Base.handle_cancellation!(::Nothing, ::UInt8) = nothing
end

# Letting another task run: there is no other task
@device_override Base.yield() = nothing

# `string(chars, strings, symbols...)` (`_string`) loops over its arguments twice, the first time to
# add up their lengths and the second to copy them, again with arguments of different types: so
# recurse over them, as in `print_to_string`
@static if isdefined(Base, :_string_n) && isdefined(Base, :__unsafe_string!)
    @device_override function Base._string(a::Union{Char, String, SubString{String}, Symbol}...)
        out = Base._string_n(string_size(a...))
        string_fill!(out, 1, a...)
        return out
    end

    string_size() = 0
    string_size(v::Char, rest...) = ncodeunits(v) + string_size(rest...)
    string_size(v::Union{String, SubString{String}}, rest...) = sizeof(v) + string_size(rest...)
    string_size(v::Symbol, rest...) = sizeof(v) + string_size(rest...)

    string_fill!(out, offs) = nothing
    function string_fill!(out, offs, v, rest...)
        offs += Base.__unsafe_string!(out, v, offs)
        return string_fill!(out, offs, rest...)
    end
end
