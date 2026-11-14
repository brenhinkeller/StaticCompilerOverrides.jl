# Differential testing: run a zero-argument function `f` in Julia and as a compiled
# standalone executable, and compare the results.
#
# Results are reduced to a single `Int` (`Bool`/integers directly, floats via their bit
# pattern) which the executable prints and the harness parses.

using Test: Test

as_int(x::Integer) = Int(x)
as_int(x::Float64) = reinterpret(Int, x)
as_int(x::Float32) = Int(reinterpret(UInt32, x))

module Wrappers using StaticTools end # holds the generated, uniquely named `main` functions
const wrapper_counter = Ref(0)

# A `main(argc, argv)` that runs the statements `body`, with a name that is `prefix` and a number (compiled entry points need real names, that are not those of other programs)
function define_main(prefix::Symbol, body::Vector)
    name = Symbol(prefix, wrapper_counter[] += 1)
    Core.eval(Wrappers, :(function $name(argc::Int, argv::Ptr{Ptr{UInt8}})
        $(body...)
        return 0
    end))
    return Base.invokelatest(getproperty, Wrappers, name)
end

# a `main(argc, argv)` that prints `as_int(f())`
make_main(f) = define_main(:static_main_, Any[:(printf(c"%ld\n", $as_int($f())))])

"""
    static_result(f; kwargs...) -> Int

Compile `f()` into a standalone executable, run it, and return its result reduced to an
`Int` (see `as_int`). Throws if compilation, linking or execution fails.
"""
function static_result(f; dir = mktempdir(), kwargs...)
    main = make_main(f)
    exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), dir, string(nameof(main)); kwargs...)
    try
        return parse(Int, readchomp(`$exe`))
    catch
        crash_backtrace(exe) # (what a crash of the program was, in the log of CI, where it can't be run again by hand)
        rethrow()
    end
end

# print a backtrace of the program, run again under a debugger, if there is one (`lldb` on macOS, `gdb` on Linux)
function crash_backtrace(exe)
    cmd = if Sys.which("lldb") !== nothing
        # (`-k` runs when the program crashes: in batch mode, nothing that is given with `-o` runs after it does)
        `lldb --batch -o run -k bt -k "register read" -k "disassemble --pc --count 40" -k "memory read --force --size 8 --count 16 \$sp" -- $exe`
    elseif Sys.which("gdb") !== nothing
        # (the address that the program was reading or writing, and the instructions at and before the one that failed: what the crash was, not only where)
        `gdb --batch -ex run -ex bt -ex "p/x \$_siginfo._sifields._sigfault.si_addr" -ex "x/8i \$pc" -ex "x/24i \$pc-64" -ex "info registers" -ex "info proc mappings" -ex "x/8gx \$rsp" $exe`
    else
        return
    end
    try
        @info "The program failed: a backtrace of it" exe
        println(stderr, read(ignorestatus(cmd), String))
    catch err
        @info "No backtrace" err
    end
    return
end

# what `f()` writes to stdout and to stderr in this process (the result, which the compiled `main`
# prints as the last line of the standard output, is returned too)
function expected_output(f)
    out_path, out_io = mktemp()
    err_path, err_io = mktemp()
    result = try
        redirect_stdout(out_io) do
            redirect_stderr(err_io) do
                r = f()
                flush(stdout); flush(stderr)
                Libc.flush_cstdio() # what was written with the streams of libc
                r
            end
        end
    finally
        close(out_io); close(err_io)
    end
    return read(out_path, String) * string(as_int(result), "\n"), read(err_path, String)
end

"""
    static_status(f; kwargs...) -> (status::Symbol, detail)

Classify how far `f()` gets as a standalone executable: `:compile_error`, `:link_error`,
`:runtime_error`, `:mismatch` or `:ok`. What `f` writes to stdout and to stderr, and what it
returns, must match what it does in Julia.
"""
function static_status(f; kwargs...)
    dir = mktempdir()
    main = make_main(f)
    exe = try
        # linker failures are reported as a failed process; everything before is "compile"
        Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), dir, string(nameof(main)); kwargs...)
    catch e
        status = e isa ProcessFailedException || occursin("failed process", sprint(showerror, e)) ?
                 :link_error : :compile_error
        return status, first(sprint(showerror, e), 300)
    end
    err_path = tempname()
    out = try
        read(pipeline(`$exe`; stderr = err_path), String)
    catch e
        crash_backtrace(exe) # (what a crash of the program was, in the log of CI, where it can't be run again by hand)
        return :runtime_error, first(sprint(showerror, e), 300)
    end
    # after compiling, which snapshots the state of any global data
    expected, expected_err = expected_output(f)
    err = read(err_path, String)
    out == expected || return :mismatch, "stdout: expected $(repr(expected)), got $(repr(out))"
    err == expected_err || return :mismatch, "stderr: expected $(repr(expected_err)), got $(repr(err))"
    return :ok, ""
end

# A `main` that runs each of `fs` in turn, writing a line with the number of the case (to the standard output, and to the standard error) before it, and the result after
function make_batch_main(fs)
    body = Any[]
    for (i, f) in enumerate(fs)
        push!(body, :(printf(c"@@case %ld@@\n", $i)), :(printf($STDERR, c"@@case %ld@@\n", $i)), :(printf(c"%ld\n", $as_int($f()))))
    end
    return define_main(:static_batch_, body)
end

# what each of `fs` writes in this process, in the same form as the batch program writes it (see `make_batch_main`): the text of the standard output and of the standard error for each
function expected_batch(fs)
    out_path, out_io = mktemp()
    err_path, err_io = mktemp()
    try
        redirect_stdout(out_io) do
            redirect_stderr(err_io) do
                for (i, f) in enumerate(fs)
                    print(stdout, "@@case ", i, "@@\n"); print(stderr, "@@case ", i, "@@\n")
                    r = f()
                    print(stdout, as_int(r), "\n")
                    flush(stdout); flush(stderr)
                    Libc.flush_cstdio() # what was written with the streams of libc
                end
            end
        end
    finally
        close(out_io); close(err_io)
    end
    return split_batch(read(out_path, String), length(fs)), split_batch(read(err_path, String), length(fs))
end

# the text of each case in the output of a batch program
function split_batch(text::AbstractString, n::Int)
    parts = fill("", n)
    marks = collect(eachmatch(r"@@case (\d+)@@\n", text))
    for (k, m) in enumerate(marks)
        i = parse(Int, m.captures[1])
        stop = k < length(marks) ? marks[k+1].offset - 1 : lastindex(text)
        1 <= i <= n && (parts[i] = text[m.offset+ncodeunits(m.match):stop])
    end
    return parts
end

"""
    static_status_batch(fs; kwargs...) -> Vector{Tuple{Symbol,String}}

`static_status` of each of the zero-argument functions `fs`, for cases that don't depend on one another (their results and what they write are compared with Julia's, as for `static_status`).
They are compiled as **one** program that runs them in turn, which takes much less time than a program for each; and if that is not `:ok` for all (it does not compile, or crashes, or
the output of some is not what Julia writes) those that are not are compiled on their own, so that each has the status that it would have.
"""
function static_status_batch(fs::AbstractVector; kwargs...)
    n = length(fs)
    n <= 1 && return Tuple{Symbol,String}[static_status(f; kwargs...) for f in fs]
    ok = Tuple{Symbol,String}[]
    mismatched = Int[]
    try
        main = make_batch_main(fs)
        exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)); kwargs...)
        err_path = tempname()
        out = read(pipeline(`$exe`; stderr = err_path), String)
        err = read(err_path, String)
        expected_out, expected_err = expected_batch(fs)
        got_out, got_err = split_batch(out, n), split_batch(err, n)
        mismatched = [i for i in 1:n if got_out[i] != expected_out[i] || got_err[i] != expected_err[i]]
    catch e
        @debug "a batch of cases was not run as one program; they are compiled one by one" exception = (e, catch_backtrace())
        mismatched = collect(1:n) # (it does not compile, or crashes: which of them is found by compiling each)
    end
    return Tuple{Symbol,String}[i in mismatched ? static_status(fs[i]; kwargs...) : (:ok, "") for i in 1:n]
end

"""
    @static_test f()

Test that the compiled standalone executable of the zero-argument call `f()` gives the same
result as Julia does.
"""
macro static_test(ex)
    quote
        Test.@test static_result(() -> $(esc(ex))) == as_int($(esc(ex)))
    end
end

# The symbols that a program may leave to the C library: the functions that `ccall` by name resolves to it (`Runtime.LIBC_FUNCTIONS`), and the ones that the runtime and the files call
const LIBC_SYMBOLS = union(Runtime.LIBC_FUNCTIONS, ["printf", "fprintf", "sigsetjmp", "siglongjmp", "fopen", "fclose", "fgetc", "ungetc", "fseek", "ftell", "getc", "putc",
                                                    "__stdoutp", "__stderrp", "__stdinp", "stdout", "stderr", "stdin"])

"""
    undefined_symbols(f, types; allow = LIBC_SYMBOLS) -> Vector{String}

Names of the functions and global variables that the compiled code of `f(types...)` uses but does not define
(excluding LLVM intrinsics and the symbols in `allow`). A nonempty result means the binary
depends on something other than libc, such as libjulia, and will not link or run standalone.
"""
function undefined_symbols(f, types; allow = LIBC_SYMBOLS, kwargs...)
    LLVM = StaticCompiler.LLVM
    try
        Base.invokelatest() do
            StaticCompiler.GPUCompiler.JuliaContext() do ctx
                mod = static_llvm_module(f, Base.to_tuple_type(types); kwargs...)
                try
                    names = [LLVM.name(x) for x in Iterators.flatten((LLVM.functions(mod), LLVM.globals(mod))) if LLVM.isdeclaration(x)]
                    return sort!(filter(n -> !startswith(n, "llvm.") && n ∉ allow, names))
                finally
                    LLVM.dispose(mod)
                end
            end
        end
    catch e
        e isa UnsupportedCodeError || rethrow()
        # what strict mode rejects
        names = String[first(d) for d in e.dynamic]
        isempty(e.pointers) || push!(names, "<$(length(e.pointers)) reference(s) to Julia objects by address>")
        return sort!(names)
    end
end

# `undefined_symbols` of the zero-argument `f` wrapped as an executable entry point
undefined_symbols(f; kwargs...) = undefined_symbols(make_main(f), (Int, Ptr{Ptr{UInt8}}); kwargs...)

const ALLOCATORS = Set(["gpu_gc_pool_alloc", "julia.gc_alloc_bytes", "jl_alloc_genericmemory_unchecked",
                        "ijl_alloc_string", "ijl_box_int64", "ijl_box_uint64", "ijl_box_int32", "ijl_box_uint32", "ijl_box_char",
                        "ijl_box_int8", "ijl_box_uint8", "ijl_box_int16", "ijl_box_uint16", "ijl_box_float32", "ijl_box_float64"])

"""
    allocation_sites(f, types) -> Int

The number of places in the compiled code of `f(types...)` that allocate heap memory (arrays,
strings, boxed values, exceptions, ...). Compiled programs have no garbage collector, so memory
allocated at each of these places is **never freed**: see the section on memory in the manual.
Zero means that the function never allocates (that Julia's optimizer removed or put on the stack
everything that looked like an allocation).

Calls that don't allocate when they are reached, such as a `throw` that is never executed, are
counted too: this is an upper bound.
"""
function allocation_sites(f, types; kwargs...)
    LLVM = StaticCompiler.LLVM
    Base.invokelatest() do
        StaticCompiler.GPUCompiler.JuliaContext() do ctx
            # (before the runtime is linked in: the allocation functions are inlined there, when the collector is used, and then they are not calls any more)
            mod = static_llvm_module(f, Base.to_tuple_type(types); strict = false, llvm_postprocess = mod -> nothing, kwargs...)
            try
                n = 0
                for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
                    inst isa LLVM.CallInst || continue
                    callee = LLVM.called_operand(inst)
                    callee isa LLVM.Function && LLVM.name(callee) in ALLOCATORS && (n += 1)
                end
                return n
            finally
                LLVM.dispose(mod)
            end
        end
    end
end
