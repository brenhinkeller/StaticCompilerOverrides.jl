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

include("runtime.jl") # The runtime functions that compiled code needs: allocation, exceptions, ...
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
OverridesParams() = OverridesParams(CANDIDATES_VERSION[])

Base.Experimental.@MethodTable(method_table)
@doc """
    StaticCompilerOverrides.method_table

The overlay method table of this package, which `@device_override` adds methods to, and which the functions
that compile (`compile_executable` and the others) use by default.
""" method_table

"""
    @device_override old_bad_method(args...) = new_good_method(args...)

Override a method that can't be compiled statically (`old_bad_method`) with one that can, in the
method table of StaticCompilerOverrides, which is the one used by the functions of this package
(`compile_executable`, ...). Unlike `StaticCompiler.@device_override`, this does not affect
compilation with StaticCompiler's own functions.
"""
macro device_override(ex)
    return esc(:($Base.Experimental.@consistent_overlay($(GlobalRef(@__MODULE__, :method_table)), $ex)))
end

# the collector is on, where it can be (it needs to know where the stack of the program starts); the environment variable
# `STATIC_COMPILER_OVERRIDES_GC` (`false`, `true`, or a number of allocations: see `gc`) is for running all the tests (or any
# program that is compiled) with another, for finding bugs in the collector
function default_gc()
    setting = get(ENV, "STATIC_COMPILER_OVERRIDES_GC", "")
    if !isempty(setting)
        n = tryparse(Int, setting)
        return n === nothing ? parse(Bool, setting) : n
    end
    return Sys.isapple() || Sys.islinux()
end

# The math library: on Linux its functions (`erfc`, which Julia code calls by name, see `libraries.jl`) are in `libm`, which is
# not linked by default, as it is on macOS (where it is part of libSystem)
default_cflags() = Sys.islinux() ? `-lm -ldl` : ``

# The target: the host, as StaticCompiler's own default, but, on macOS, with a version in the triple. StaticCompiler's triple for it
# has none (`aarch64-apple-darwin`), so the object files have no "platform load command", which says what system they are for, and the
# linker of recent versions of macOS warns about each (`no platform load command found in 'x.o', assuming: macOS`). The oldest version that
# exists for the architecture is used, which is what the binary says that it needs at least.
function default_target()
    Sys.isapple() || return StaticCompiler.StaticTarget()
    arch, minimum = Sys.ARCH === :x86_64 ? ("x86_64", "10.13.0") : ("aarch64", "11.0.0")
    return StaticCompiler.StaticTarget(string(arch, "-apple-macosx", minimum), LLVM.host_cpu_name(), LLVM.host_cpu_features())
end

# StaticCompiler's entry points, with our method table as the default, and the runtime of this
# package installed in the code that they generate (`llvm_postprocess`)
for f in (:compile_executable, :compile_shlib, :static_code_llvm, :static_code_typed,
          :static_code_native, :static_llvm_module)
    @eval begin
        function $f(args...; method_table = method_table, params = nothing, strict::Bool = true, allow = (), gc = default_gc(), target = default_target(),
                    libraries::Symbol = :system,
                    llvm_postprocess = mod -> (report_registered_dispatch(); link_runtime!(mod; strict, allow, gc, libraries)), kwargs...)
            libraries in (:system, :bundle) || throw(ArgumentError("`libraries` is `:system` or `:bundle`, not `$(repr(libraries))`"))
            register_custom_deepcopy!() # (this can change the parameters: they have the version of the lists of types)
            params === nothing && (params = OverridesParams())
            $(f in (:compile_executable, :compile_shlib) ?
                :(length(args) >= 2 && args[1] isa Function && args[2] isa Tuple && check_entry(args[1], args[2]; method_table, params, target)) : :nothing)
            result = StaticCompiler.$f(args...; method_table, params, target, llvm_postprocess,
                              $(f in (:compile_executable, :compile_shlib) ? :(merge((; cflags = default_cflags()), NamedTuple(kwargs))...) : :(kwargs...)))
            $(f in (:compile_executable, :compile_shlib) ? :(libraries === :bundle && result isa AbstractString && Runtime.bundle_libraries(result)) : :nothing)
            return result
        end
        @doc """
            $($f)(args...; method_table = StaticCompilerOverrides.method_table, strict = true, allow = (), kwargs...)

        `StaticCompiler.$($f)`, using the method table of StaticCompilerOverrides by default, and with its
        runtime (allocation, exceptions, ...) added to the code that is generated.

        By default (`strict = true`) the code is rejected with an [`UnsupportedCodeError`](@ref) if
        it contains something that can't work in a standalone binary: calls that need the Julia runtime
        (most often, dynamic dispatch), or references to Julia objects by their address. `strict = false`
        compiles it anyway, with calls that need the runtime aborting the program if they are reached.
        `allow` is a collection of names of runtime functions (as in the error message) to accept even
        in strict mode. A call on a value of `Any` (or of an abstract type that can't be listed) is made over the registered types (see
        [`add_dispatch_candidates!`](@ref)), and compiling says so in a debug message (`JULIA_DEBUG=StaticCompilerOverrides`).

        `libraries` is where a program looks for the libraries that it calls functions of (BigInt, Regex, a JLL, a library of yours): `:system` (the default)
        at the path that they have when compiling, or `:bundle`, in the folder `lib` next to the program, where they are copied (those that they need as
        well), and, if they are not there, at that path.

        By default (`gc = true`, where the collector is available) the program has a garbage collector: memory that is not
        used any more is freed (see the section on memory in the manual). `gc = false` never frees it. A number
        (`gc = 100`) also collects every that many allocations and overwrites what it frees, which is for finding bugs
        in the collector.
        """ $f
    end
end

## Entry points that take the arguments of the command line

"The arguments of the command line, without the name of the program, as in `Base.ARGS`."
function command_line_arguments(argc::Int, argv::Ptr{Ptr{UInt8}})
    args = Vector{String}(undef, max(argc - 1, 0))
    for i in 2:argc
        args[i-1] = unsafe_string(unsafe_load(argv, i))
    end
    return args
end

# what the entry point of `f(args::Vector{String})` does: `ARGS` is also set, as it is in Julia,
# and the result of `f` is the exit status of the program (if it is an integer)
function run_entry(f, argc::Int, argv::Ptr{Ptr{UInt8}})
    args = command_line_arguments(argc, argv)
    # (`ARGS` of the binary is the vector of the Julia that compiled it, with what that had in it: the arguments of the command line of that)
    empty!(Base.ARGS)
    append!(Base.ARGS, args)
    status = f(args)
    return status isa Integer ? Int(status) : 0
end

# A function `main(argc::Int, argv::Ptr{Ptr{UInt8}})` that runs `f(args)`, named `name`. The entry
# point of the executable has the name of the function, so it is made in a module of its own.
function entry_point(f, name::AbstractString)
    entry = Module(:StaticEntryPoint)
    Core.eval(entry, :(function $(Symbol(name))(argc::Int, argv::Ptr{Ptr{UInt8}})
        return $run_entry($f, argc, argv)
    end))
    return Base.invokelatest(getproperty, entry, Symbol(name))
end

"""
    compile_executable(f, (Vector{String},), [path], [name]; kwargs...)

Compile an executable that runs `f(args)`, where `args` are the arguments of the command line, as
`ARGS` is in Julia (they are also available as `ARGS`). If `f` returns an integer, it is the exit
status of the program. This is the convention of Julia's `main(args)`:

```julia
function main(args::Vector{String})
    println("Hello, ", isempty(args) ? "world" : args[1], "!")
end
compile_executable(main, (Vector{String},))
```
"""
function compile_executable(f::Function, types::Tuple{DataType}, args...; kwargs...)
    # (the type of a tuple of types is a tuple of `DataType`s: it is the value that tells)
    types == (Vector{String},) || return invoke(compile_executable, Tuple{Vararg{Any}}, f, types, args...; kwargs...)
    return compile_executable_with_arguments(f, args...; kwargs...)
end

function compile_executable_with_arguments(f::Function, path::String = pwd(), name::AbstractString = string(nameof(f)); kwargs...)
    entry = entry_point(f, name)
    # (the entry point was just defined, so look at the latest world)
    return Base.invokelatest(compile_executable, entry, (Int, Ptr{Ptr{UInt8}}), path, String(name); kwargs...)
end
