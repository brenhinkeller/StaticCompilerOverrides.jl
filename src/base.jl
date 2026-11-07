# Overrides of methods of Base (and the standard libraries) that can be written in a way that
# compiles statically, with the same behavior.

# `print_to_string(xs...)`, which `string`, error messages and `sprint`-like helpers use, loops
# over its arguments as `for i in 1:nfields(xs); print(s, xs[i]); end`. When the arguments have
# different types, the type of `xs[i]` depends on `i`, which is not known when compiling, so every
# call becomes a dynamic dispatch. Recursing over the tuple gives each element its own type.
@device_override function Base.print_to_string(xs...)
    isempty(xs) && return ""
    s = IOBuffer(sizehint = sizehint_sum(xs...))
    print_each(s, xs...)
    return Base.takestring!(s)
end

sizehint_sum() = 0
sizehint_sum(x, xs...) = Base._str_sizehint(x) + sizehint_sum(xs...)

print_each(s) = nothing
function print_each(s, x, xs...)
    print(s, x)
    return print_each(s, xs...)
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
