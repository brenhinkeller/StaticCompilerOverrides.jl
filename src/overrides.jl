# The method table of this package, and the entry points that use it.
#
# StaticCompiler compiles with an overlay method table (`StaticCompiler.method_table`) that holds
# overrides of Base methods that can't be compiled. That table includes overrides, from
# `quirks.jl`, that replace the error helpers of Base with functions that print and exit; they
# made sense before compiled code could throw, but they prevent errors from being caught.
#
# A compilation uses exactly one overlay table (overlays do not stack), with Base itself as the
# fallback. So we have a table of our own, which contains only the overrides defined by this
# package, and compile with it by default: the `quirks.jl` overrides do not apply, and Julia's
# own error helpers (which throw) are used. The functions below are StaticCompiler's entry points,
# defaulting to this table. Pass `method_table = StaticCompiler.method_table` for the old behavior.

include("runtime/runtime.jl") # The runtime functions that compiled code needs: allocation, exceptions, ...
using .Runtime: link_runtime!, UnsupportedCodeError

# The parameters of the compilations of this package. GPUCompiler's functions that we specialize (`inference_params`,
# `optimize!`, ...) are for this type, which is ours, and so they don't change what StaticCompiler's own compilations do.
#
# It also has the number of times that the list of registered types (`add_show_candidates!`, `add_dispatch_candidates!`) has
# changed. GPUCompiler keeps what it infers apart for each value of the parameters, so what is inferred with a list of types
# is not used for compiling with another (it would be, if the type were just a type, with the dispatch that was made for the list
# that was there when a method was first inferred).
struct OverridesParams <: GPUCompiler.AbstractCompilerParams
    candidates::Int
end
const CANDIDATES_VERSION = Ref(0)

# The types of functions (the types of closures, `typeof(sin)`) that a call of a function that is not known when compiling (`f(x)` of an `f` of the type `Function` or `Any`, from a
# `Vector{Function}`, a `Dict`, a variable that a closure captures and is changed) is made over: those that were found in the code that is compiled (see closures.jl). The
# list is the one of the compilation that is made now, and what is inferred is kept apart for each (`OverridesParams()` has a number made from it).
const FUNCTION_CANDIDATES = Type[]

# The callbacks of the program that is compiled now: the types that were registered with `note_callback` (see closures.jl), each with the type of the value that it is called with
const CALLBACK_CANDIDATES = Tuple{Type,Type}[]
OverridesParams() = OverridesParams(hash(BOX_VERSION[], hash(CALLBACK_CANDIDATES, hash(FUNCTION_CANDIDATES, hash(CANDIDATES_VERSION[])))) % Int)

Base.Experimental.@MethodTable(method_table)
@doc """
    StaticRuntime.method_table

The overlay method table of this package, which `@device_override` adds methods to, and which the functions
that compile (`compile_executable` and the others) use by default.
""" method_table

"""
    @device_override old_bad_method(args...) = new_good_method(args...)

Override a method that can't be compiled statically (`old_bad_method`) with one that can, in the
method table of StaticRuntime, which is the one used by the functions of this package
(`compile_executable`, ...). Unlike `StaticCompiler.@device_override`, this does not affect
compilation with StaticCompiler's own functions.
"""
macro device_override(ex)
    return esc(:($Base.Experimental.@consistent_overlay($(GlobalRef(@__MODULE__, :method_table)), $ex)))
end

# `gc` is `:auto`, where the collector is available (it needs to know where the stack of the program starts): the program has the collector if it needs it (see `allocation_is_finite`), and not otherwise.
# The environment variable `STATIC_RUNTIME_GC` (`auto`, `false`, `true`, or a number of allocations: see `gc`) is for running all the tests (or any
# program that is compiled) with another, for finding bugs in the collector
function default_gc()
    setting = get(ENV, "STATIC_RUNTIME_GC", "")
    if !isempty(setting)
        setting == "auto" && return :auto
        n = tryparse(Int, setting)
        return n === nothing ? parse(Bool, setting) : n
    end
    return Sys.isapple() || Sys.islinux() ? :auto : false
end

# Whether the program is optimized once more after it is linked (`optimize = true`: the pipeline `O2` of the optimizer, on the whole program, see `inline_internal_functions!`). Not by default. The environment variable
# `STATIC_RUNTIME_OPTIMIZE` (`true` or `false`) sets the default, for running all of the tests with it.
default_optimize() = get(ENV, "STATIC_RUNTIME_OPTIMIZE", "false") in ("true", "1", "yes")

# what `gc` can be: `true` (the collector is always in the program), `false` (never), `:auto` (it is if the program needs it), or a number of allocations (the collector is always in, and runs that often)
check_gc(gc) = (gc isa Bool || gc === :auto || gc isa Integer) ||
    throw(ArgumentError("`gc` is `true`, `false`, `:auto`, or a number of allocations, not `$(repr(gc))`"))

# The math library: on Linux its functions (`erfc`, which Julia code calls by name, see `runtime/libraries.jl`) are in `libm`, which is
# not linked by default, as it is on macOS (where it is part of libSystem).
#
# With `small = true`, what the file has that the program does not need is left out. On macOS, the names of the functions that are not exported (all of those of the program, but its entry
# point; `-x`): a program does not look at them, and they are 5 to 25 kB; and the segment of the constants and the table of the addresses of functions, which is made read-only when the program
# starts (`-no_data_const`): it is a page of 16 kB, and a program of a few kilobytes has a few hundred bytes in it. On Linux, the symbols (`-s`: not tried yet).
function default_cflags(small::Bool = false)
    Sys.islinux() && return small ? `-lm -ldl -Wl,-s` : `-lm -ldl`
    Sys.isapple() && small && return `-Wl,-x -Wl,-no_data_const`
    return ``
end

# The target: the host, as StaticCompiler's own default, but, on macOS, with a version in the triple. StaticCompiler's triple for it
# has none (`aarch64-apple-darwin`), so the object files have no "platform load command", which says what system they are for, and the
# linker of recent versions of macOS warns about each (`no platform load command found in 'x.o', assuming: macOS`). The oldest version that
# exists for the architecture is used, which is what the binary says that it needs at least.
function default_target()
    Sys.isapple() || return StaticCompiler.StaticTarget()
    arch, minimum = Sys.ARCH === :x86_64 ? ("x86_64", "10.13.0") : ("aarch64", "11.0.0")
    features = LLVM.host_cpu_features()
    # On Apple Silicon, without `fuse-literals`: the CPU model of the Apple cores has it, and with it the code generator makes every
    # floating-point constant that is not tiny from four integer instructions (`mov`, three `movk`) and a `fmov`, in place of one load from
    # the constant pool, which is what it does for the generic CPU, and what the C library does. The math functions of Julia (`log`, `exp`,
    # `atan`, `pow`, ...) have tens of constants each, and are 15% to 35% slower with it; nothing else changes, in speed or size.
    arch == "aarch64" && (features = isempty(features) ? "-fuse-literals" : features * ",-fuse-literals")
    return StaticCompiler.StaticTarget(string(arch, "-apple-macosx", minimum), LLVM.host_cpu_name(), features)
end

# StaticCompiler's entry points, with our method table as the default, and the runtime of this
# package installed in the code that they generate (`llvm_postprocess`)
for f in (:compile_executable, :compile_shlib, :static_code_typed, :static_llvm_module)
    @eval begin
        function $f(args...; method_table = method_table, params = nothing, strict::Bool = true, stub_errors::Bool = true, allow = (), gc = default_gc(), target = default_target(),
                    libraries::Symbol = :system, small::Bool = false, optimize::Bool = default_optimize(),
                    llvm_postprocess = mod -> (report_registered_dispatch(); link_runtime!(mod; strict, stub_errors, allow, gc, libraries, optimize, bounded = $(f in (:compile_executable, :static_llvm_module)))), kwargs...)
            libraries in (:system, :bundle) || throw(ArgumentError("`libraries` is `:system` or `:bundle`, not `$(repr(libraries))`"))
            check_gc(gc)
            register_custom_deepcopy!() # (this can change the parameters: they have the version of the lists of types)
            explicit_params = params
            run(extra) = with_function_candidates(; strict) do
                job_params = explicit_params === nothing ? OverridesParams() : explicit_params
                $(f in (:compile_executable, :compile_shlib) ?
                    :(length(args) >= 2 && args[1] isa Function && args[2] isa Tuple && check_entry(args[1], args[2]; method_table, params = job_params, target)) : :nothing)
                entry_args = rooted_arguments(args)
                Base.invokelatest(StaticCompiler.$f, entry_args...; method_table, params = job_params, target, llvm_postprocess,
                                  $(f in (:compile_executable, :compile_shlib) ? :(merge((; cflags = default_cflags(small)), NamedTuple(kwargs), extra)...) : :(merge(NamedTuple(kwargs), extra)...)))
            end
            result = try
                run((;))
            catch e
                # (the debug information, which says where in the Julia code the calls of the runtime are, is removed before the code is checked: when it is not accepted, it is made again with it)
                (e isa UnsupportedCodeError && strict && !haskey(kwargs, :strip)) || rethrow()
                detailed = try run((; strip = false)); nothing catch e2; e2 end
                throw(detailed isa UnsupportedCodeError ? detailed : e)
            end
            $(f in (:compile_executable, :compile_shlib) ? :(libraries === :bundle && result isa AbstractString && Runtime.bundle_libraries(result)) : :nothing)
            return result
        end
        @doc """
            $($f)(args...; method_table = StaticRuntime.method_table, strict = true, allow = (), kwargs...)

        `StaticCompiler.$($f)`, using the method table of StaticRuntime by default, and with its
        runtime (allocation, exceptions, ...) added to the code that is generated.

        By default (`strict = true`) the code is rejected with an [`UnsupportedCodeError`](@ref) if
        it contains something that can't work in a standalone binary: calls that need the Julia runtime
        (most often, dynamic dispatch), or references to Julia objects by their address. `strict = false`
        compiles it anyway, with calls that need the runtime aborting the program if they are reached.
        `allow` is a collection of names of runtime functions (as in the error message) to accept even
        in strict mode. A call on a value of `Any` (or of an abstract type that can't be listed) is made over the registered types (see
        [`add_dispatch_candidates!`](@ref)), and compiling says so in a debug message (`JULIA_DEBUG=StaticRuntime`).

        `libraries` is where a program looks for the libraries that it calls functions of (BigInt, Regex, a JLL, a library of yours): `:system` (the default)
        at the path that they have when compiling, or `:bundle`, in the folder `lib` next to the program, where they are copied (those that they need as
        well), and, if they are not there, at that path.

        `gc` says whether the program has a garbage collector. By default (`gc = :auto`, where the collector is available) it has one if it needs it: a program that allocates only a finite amount of memory in all
        (nothing that is allocated is in a loop, or in a function that is called from one or that calls itself, or that a library calls; what makes the arguments of the command line, and what is allocated only to
        stop with an error, are not counted) never frees anything, and has the allocator that does not collect (see [Binary size](@ref)). A library, `compile_shlib`, can be called any number of
        times, so there only what is allocated to stop with an error is not counted. `gc = true` always has the collector: memory that is not used any more is freed (see the section on memory in the manual).
        `gc = false` never has it, and never frees memory. A number (`gc = 100`) is `true` that also collects every that many allocations and overwrites what it frees, which is for finding bugs
        in the collector.

        `optimize = true` optimizes the program once more after it is linked (the pipeline `O2` of LLVM on the whole program): recursion and allocation can be faster. The program can add up a reduction in `@simd`
        (or the elements of a `Float16` sum) in another order than Julia does, and so give another result in the last digits. It is `false` by default.

        `small = true` makes a smaller file, where that can be done without a difference in what the program does: the linker leaves out what the program does not look at (the names of its functions, a
        segment of constants on macOS).
        """ $f
    end
end

"""
    static_code_llvm(f, types; io = stdout, kwargs...)

Write the LLVM IR of the compiled `f(types...)`, as it is when the program is made (with the runtime of this package, and the objects that it refers to in it), to `io`.
The options are those of [`static_llvm_module`](@ref).
"""
function static_code_llvm(f, types; io::IO = stdout, kwargs...)
    tt = Base.to_tuple_type(types)
    StaticCompiler.GPUCompiler.JuliaContext() do ctx
        mod = static_llvm_module(f, tt; kwargs...)
        try
            print(io, string(mod))
        finally
            LLVM.dispose(mod)
        end
    end
    return nothing
end

"""
    static_code_native(f, types; io = stdout, kwargs...)

Write the assembly of the compiled `f(types...)` to `io`. The options are those of [`static_llvm_module`](@ref).
"""
function static_code_native(f, types; io::IO = stdout, target = default_target(), method_table = method_table, params = nothing, kwargs...)
    tt = Base.to_tuple_type(types)
    StaticCompiler.GPUCompiler.JuliaContext() do ctx
        mod = static_llvm_module(f, tt; target, method_table, params, kwargs...)
        try
            job, _ = StaticCompiler.static_job(f, tt; target, method_table, params = params === nothing ? OverridesParams() : params)
            asm, _ = StaticCompiler.GPUCompiler.emit_asm(job, mod, LLVM.CodeGenFileType.Assembly)
            print(io, asm isa AbstractString ? asm : String(asm))
        finally
            LLVM.dispose(mod)
        end
    end
    return nothing
end

## Entry points that take the arguments of the command line

"The arguments of the command line, without the name of the program, as in `Base.ARGS`. (Not inlined: the allocations in its loop are as many as the arguments, which `allocation_is_finite` has to know.)"
@noinline function command_line_arguments(argc::Int, argv::Ptr{Ptr{UInt8}})
    args = Vector{String}(undef, max(argc - 1, 0))
    for i in 2:argc
        args[i-1] = unsafe_string(unsafe_load(argv, i))
    end
    return args
end

# `ARGS` of the binary is the vector of the Julia that compiled it, with what that had in it: the arguments of the command line of that. (Not inlined, like `command_line_arguments`: what these two
# allocate is as much as the arguments are, and `allocation_is_finite` ignores it: it knows them by their names.)
@noinline function set_base_args(args::Vector{String})
    empty!(Base.ARGS)
    append!(Base.ARGS, args)
    return nothing
end

# The exit status of the program is the integer that `f` returns, and 0 if it returns something else (`nothing`, for one): the entry point
# that StaticCompiler makes of `f` itself has whatever is in the register of the result, when `f` does not return an integer.
exit_status(status) = status isa Integer ? Int(status) : 0

# what the entry point of `f(args::Vector{String})` does: `ARGS` is also set, as it is in Julia
function run_entry(f, argc::Int, argv::Ptr{Ptr{UInt8}})
    args = command_line_arguments(argc, argv)
    set_base_args(args)
    return exit_status(f(args))
end

# what the entry point of `f()` does: `ARGS` is empty (and not what it has when compiling)
function run_entry_without_arguments(f, argc::Int, argv::Ptr{Ptr{UInt8}})
    empty!(Base.ARGS)
    return exit_status(f())
end

# A function `main(argc::Int, argv::Ptr{Ptr{UInt8}})` that runs `f(args)` (or `f()`, with `arguments = false`), named `name`. The entry
# point of the executable has the name of the function, so it is made in a module of its own.
function entry_point(f, name::AbstractString; arguments::Bool = true)
    entry = Module(:StaticEntryPoint)
    runner = arguments ? run_entry : run_entry_without_arguments
    Core.eval(entry, :(function $(Symbol(name))(argc::Int, argv::Ptr{Ptr{UInt8}})
        return $runner($f, argc, argv)
    end))
    return Base.invokelatest(getproperty, entry, Symbol(name))
end

"""
    compile_executable(f, (Vector{String},), [path], [name]; kwargs...)
    compile_executable(f, (), [path], [name]; kwargs...)
    compile_executable(f; kwargs...)

Compile an executable that runs `f(args)`, where `args` are the arguments of the command line, as
`ARGS` is in Julia (they are also available as `ARGS`), or `f()`, for a program that takes no arguments
(`compile_executable(f)` is the same; `ARGS` is empty). If `f` returns an integer, it is the exit
status of the program, and it is 0 if `f` returns anything else (`nothing`, for one). This is the convention of Julia's `main(args)`:

```julia
function main(args::Vector{String})
    println("Hello, ", isempty(args) ? "world" : args[1], "!")
end
compile_executable(main, (Vector{String},))
```

The third form of the entry point is C's: `compile_executable(f, (Int, Ptr{Ptr{UInt8}}))` compiles `f(argc, argv)` to the `main` of a C program,
with the arguments as C has them. The exit status is then what `f` returns, which has to be an integer (`Int` or `Int32`): for anything else it is not defined.
"""
function compile_executable(f::Function, types::Tuple{DataType}, args...; kwargs...)
    # (the type of a tuple of types is a tuple of `DataType`s: it is the value that tells)
    types == (Vector{String},) || return invoke(compile_executable, Tuple{Vararg{Any}}, f, types, args...; kwargs...)
    return compile_executable_with_arguments(f, args...; kwargs...)
end
compile_executable(f::Function, types::Tuple{}, args...; kwargs...) = compile_executable_with_arguments(f, args...; arguments = false, kwargs...)
compile_executable(f::Function; kwargs...) = compile_executable(f, (); kwargs...)

function compile_executable_with_arguments(f::Function, path::String = pwd(), name::AbstractString = string(nameof(f)); arguments::Bool = true, kwargs...)
    entry = entry_point(f, name; arguments)
    # (the entry point was just defined, so look at the latest world)
    return Base.invokelatest(compile_executable, entry, (Int, Ptr{Ptr{UInt8}}), path, String(name); kwargs...)
end
