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

# a named `main(argc, argv)` that prints `as_int(f())`; compiled entry points need real names
function make_main(f)
    name = Symbol(:static_main_, wrapper_counter[] += 1)
    Core.eval(Wrappers, :(function $name(argc::Int, argv::Ptr{Ptr{UInt8}})
        printf(c"%ld\n", $as_int($f()))
        return 0
    end))
    return Base.invokelatest(getproperty, Wrappers, name)
end

"""
    static_result(f; kwargs...) -> Int

Compile `f()` into a standalone executable, run it, and return its result reduced to an
`Int` (see `as_int`). Throws if compilation, linking or execution fails.
"""
function static_result(f; dir = mktempdir(), kwargs...)
    main = make_main(f)
    exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), dir, string(nameof(main)); kwargs...)
    return parse(Int, readchomp(`$exe`))
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
        return :runtime_error, first(sprint(showerror, e), 300)
    end
    # after compiling, which snapshots the state of any global data
    expected, expected_err = expected_output(f)
    err = read(err_path, String)
    out == expected || return :mismatch, "stdout: expected $(repr(expected)), got $(repr(out))"
    err == expected_err || return :mismatch, "stderr: expected $(repr(expected_err)), got $(repr(err))"
    return :ok, ""
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

const LIBC_SYMBOLS = Set(["malloc", "calloc", "free", "puts", "exit", "printf", "memcpy", "memmove",
                          "memset", "memcmp", "strlen", "fwrite", "fputs", "abort", "sigsetjmp", "siglongjmp",
                          "getentropy", "fopen", "fclose", "fread", "fputc", "fgetc", "ungetc", "fseek", "ftell",
                          "fflush", "fprintf", "usleep", "getc", "putc", "__stdoutp", "__stderrp", "__stdinp", "stdout",
                          "stderr", "stdin"])

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
                        "ijl_alloc_string", "ijl_box_int64", "ijl_box_uint64", "ijl_box_int32", "ijl_box_uint32", "ijl_box_char"])

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
            mod = static_llvm_module(f, Base.to_tuple_type(types); strict = false, kwargs...)
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
