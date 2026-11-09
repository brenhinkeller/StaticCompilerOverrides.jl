# Regex: PCRE2 (a library that the program calls, see `libraries.jl`) matches, and the pieces of Base that are for threads are one thing here.
#
# * The context of a match (and the stack of the JIT) is one for the program, made when it is first needed: Base keeps one for each thread, in a
#   global that is a `Vector`, with a lock for the one that adds to it (`get_local_match_context`).
# * A `Regex` is compiled when it is first used (its `regex` field is null until then): the lock that Base takes for that is not needed.
#   (A `Regex` that was compiled in the process that compiles the program has the address of the code of PCRE in it, which is not an address in
#   the program: it is not copied, see `field_cut` in `runtime.jl`.)

const MATCH_CONTEXT = Ref{Ptr{Cvoid}}(C_NULL)

@device_override function Base.PCRE.get_local_match_context()
    ctx = MATCH_CONTEXT[]
    if ctx == C_NULL
        ctx = Base.PCRE.create_match_context()
        MATCH_CONTEXT[] = ctx
    end
    return ctx
end

@device_override function Base.compile(regex::Regex)
    if regex.regex == C_NULL
        regex.regex = Base.PCRE.compile(regex.pattern, regex.compile_options)
        Base.PCRE.jit_compile(regex.regex)
    end
    return regex
end

# A `Regex` that is made when the program runs has a finalizer in Base, to free its compiled code. A finalizer that is a Julia function is not
# supported (the collector runs C functions: see `heap.jl`), so these are not freed: the code of a pattern (a few kilobytes) stays until the program ends.
# (The `Regex` that are constants of the program are not freed either way.)
@device_override Base.finalizer(f, regex::Regex) = regex
