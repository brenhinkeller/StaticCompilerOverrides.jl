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

# `t[i]` of a tuple (and so a loop over one, `iterate`, `collect`, `enumerate`, `Dict(pairs...)`) with an `i` that is not known when compiling is `getfield(t, i)`,
# which for the elements of different types has a type that depends on `i`: Julia makes it a call of the runtime that looks the field up and boxes it.
# One comparison for each element gives each its own type, and the result is the union of them, which is split when it is used (as the value of a
# `Union` is); for a constant `i` the comparisons are folded, and for a tuple of one type they are selects. There is a method for each number of
# elements up to 32 (more are `getfield`), written out: a recursion over the tuple is not inlined, and then a constant `i` no longer finds the element
# without making the tuple, which for a type of element that is a `Union` is made by the runtime (the `iterate` of an array returns such a tuple, and
# the element is taken out of it by `y[1]`); nor is the method that calls these, unless it is `@inline`. Not a generated function: they can't be
# inferred for a tuple type that is not concrete, as `Tuple{Union{Int,String},Int}`, the type of what `iterate` returns, is not.
@inline tuple_getindex(t::Tuple, i::Int) = getfield(t, i)
for n in 2:32
    pattern = Expr(:curly, :Tuple, ntuple(_ -> :Any, n)...)
    chain = :(throw(BoundsError(t, i)))
    for k in n:-1:1
        chain = :(i == $k ? getfield(t, $k) : $chain)
    end
    @eval @inline tuple_getindex(t::$pattern, i::Int) = $chain
end
@device_override @inline Base.getindex(t::Tuple, i::Int) = tuple_getindex(t, i)

# Base's `iterate` of a tuple is `@nospecialize`d, so it is compiled for any tuple, and its `t[i]` is a `getfield` with an index that is not known: for a tuple
# that has elements stored inline next to ones that are references (`Tuple{Int,Any}`, which `string(1, x)` is called with), that is not code that can be made
# without the runtime. This one is specialized for the tuple, and so uses the `getindex` above.
@device_override @inline Base.iterate(t::Tuple, i::Int = 1) = (1 <= i <= length(t)) ? (@inbounds(t[i]), i + 1) : nothing

# `string(1, x)` (and so `"a=$(1) b=$(x)"`) where `x` is not known when compiling (a value of `Any`): the arguments are a `Tuple{Int,Any}`, which is not a concrete type
# (the type of the tuple depends on `x`), so making it, and taking an element of it, is a call of the runtime. With the arguments one by one it is not made.
# (Without an `Any` in them the methods of Base are used as they were: those for strings and characters are more specific.)
for n in 2:12
    args = [Symbol(:x, i) for i in 1:n]
    @eval @device_override function Base.string($(args...))
        s = IOBuffer()
        io = BufIO(s) # (the methods of `show` in `show.jl` are for a `BufIO`, as in `print_to_string` above)
        $([:(print(io, $a)) for a in args]...)
        return Base.takestring!(s)
    end
end

# `splice!` of a vector, written with `deleteat!` and `insert!` (Base's has a tuple of unknown type in it)
@device_override function Base.splice!(a::Vector, i::Integer, ins = Base._default_splice)
    v = a[i]
    deleteat!(a, i)
    k = 0
    for x in ins
        insert!(a, i + k, x)
        k += 1
    end
    return v
end
@device_override function Base.splice!(a::Vector, r::AbstractUnitRange{<:Integer}, ins = Base._default_splice)
    v = a[r]
    deleteat!(a, r)
    k = 0
    for x in ins
        insert!(a, first(r) + k, x)
        k += 1
    end
    return v
end

# `sleep` is a timer of libuv, which needs the event loop. Here it is `nanosleep` (started again with the time that is left if a signal interrupts it)
@device_override function Base.sleep(sec::Real)
    sec >= 0 || throw(ArgumentError("sleep time must be nonnegative, got $sec"))
    isnan(sec) && throw(ArgumentError("sleep time must not be NaN"))
    whole = floor(min(Float64(sec), 1e15))
    nanos = round(Int64, (min(Float64(sec), 1e15) - whole) * 1e9)
    whole_s = Int64(whole)
    nanos >= 1_000_000_000 && (whole_s += 1; nanos -= 1_000_000_000)
    request = Ref((whole_s, nanos))
    left = Ref((Int64(0), Int64(0)))
    while ccall(:nanosleep, Cint, (Ref{NTuple{2,Int64}}, Ref{NTuple{2,Int64}}), request, left) != 0
        request[] = left[]
    end
    return nothing
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
    string_size(v::Symbol, rest...) = symbol_length(v) + string_size(rest...)

    string_fill!(out, offs) = nothing
    function string_fill!(out, offs, v, rest...)
        offs += Base.__unsafe_string!(out, v, offs)
        return string_fill!(out, offs, rest...)
    end
end

# `Symbol`s whose value is not known when compiling (the name of a function in a message, taken from a field). Base asks libjulia for the
# bytes of a `Symbol` (`jl_symbol_name`) and for how long they are (`sizeof`, a builtin that is a call into the runtime when it can't be
# folded). The name is stored right after the three pointers of the node of the symbol table (`jl_sym_t`), and ends with a NUL.
symbol_pointer(s::Symbol) = Ptr{UInt8}(Base.pointer_from_objref(s)) + 3 * sizeof(Ptr{Cvoid})
symbol_length(s::Symbol) = Int(@symbolcall strlen(symbol_pointer(s)::Ptr{UInt8})::Int64)

@device_override Base.unsafe_convert(::Type{Ptr{UInt8}}, s::Symbol) = symbol_pointer(s)
@device_override Base.unsafe_convert(::Type{Ptr{Int8}}, s::Symbol) = Ptr{Int8}(symbol_pointer(s))
@device_override Base._str_sizehint(s::Symbol) = symbol_length(s)
@device_override function Base.__unsafe_string!(out, s::Symbol, offs::Integer)
    n = symbol_length(s)
    GC.@preserve s out unsafe_copyto!(pointer(out, offs), symbol_pointer(s), n)
    return n
end
@device_override Base.print(io::IO, s::Symbol) = (unsafe_write(io, symbol_pointer(s), UInt(symbol_length(s))); nothing)
@device_override Base.write(io::IO, s::Symbol) = Int(unsafe_write(io, symbol_pointer(s), UInt(symbol_length(s))))

# The clocks of libc (`jl_hrtime` and `jl_clock_now` are libjulia's, which is not there)
function clock_nanoseconds(id::Int32)
    ts = Ref((Int64(0), Int64(0))) # `struct timespec`: seconds and nanoseconds
    GC.@preserve ts begin
        @symbolcall clock_gettime(id::Int32, Base.unsafe_convert(Ptr{NTuple{2,Int64}}, ts)::Ptr{NTuple{2,Int64}})::Int32
    end
    sec, nsec = ts[]
    return UInt64(sec) * UInt64(1_000_000_000) + UInt64(nsec)
end
const CLOCK_REALTIME = Int32(0)
const CLOCK_MONOTONIC = Sys.isapple() ? Int32(6) : Int32(1)
@device_override Base.time_ns() = clock_nanoseconds(CLOCK_MONOTONIC)
@device_override Base.time() = clock_nanoseconds(CLOCK_REALTIME) / 1e9

# There is one thread
@device_override Base.Threads.nthreads() = 1

# `@assert cond "message $x"` (a message that is not a literal) makes the message with `_assert_tostring`, which is opaque to the
# compiler on purpose (`Core.compilerbarrier`), so it is a call on an `Any`. The message is a `String`, nearly always, and then
# there is nothing to do.
@device_override Base._assert_tostring(msg::String) = msg

# Deprecation warnings (`Base.depwarn`, which packages call from the methods that are deprecated) look at the options of the
# Julia that runs (`JLOptions()`, `--depwarn`), which a program does not have; and are not shown by default: nothing is done
@device_override Base.depwarn(msg, funcsym; force::Bool = false) = nothing
@static if isdefined(Base, :depwarn_if_not_pure)
    @device_override Base.depwarn_if_not_pure(args...) = nothing # (the deprecated properties of types, `Type.name`, which `@deprecate` reads)
end

# The time of day: `jl_gettimeofday` is a function of libjulia; `gettimeofday` is that of the C library (so `Dates.now()` and `today()` work: the zone is
# that of the machine that runs the program, from `localtime_r`)
@device_override function Base.Libc.TimeVal()
    tv = Ref{Base.Libc.TimeVal}()
    status = ccall(:gettimeofday, Cint, (Ref{Base.Libc.TimeVal}, Ptr{Cvoid}), tv, C_NULL)
    status != 0 && error("unable to determine current time: ", status)
    return tv[]
end
