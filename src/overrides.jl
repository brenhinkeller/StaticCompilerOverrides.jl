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

Base.Experimental.@MethodTable(method_table)

"""
    @device_override old_bad_method(args...) = new_good_method(args...)

Override a method that can't be compiled statically (`old_bad_method`) with one that can, in the
method table of StaticCompilerOverrides, which is the one used by the functions of this package
(`compile_executable`, ...). Unlike `StaticCompiler.@device_override`, this does not affect
compilation with StaticCompiler's own functions.
"""
macro device_override(ex)
    return esc(:($Base.Experimental.@overlay($(GlobalRef(@__MODULE__, :method_table)), $ex)))
end

# StaticCompiler's entry points, with our method table as the default, and the runtime of this
# package installed in the code that they generate (`llvm_postprocess`)
for f in (:compile_executable, :compile_shlib, :static_code_llvm, :static_code_typed,
          :static_code_native, :static_llvm_module)
    @eval begin
        $f(args...; method_table = method_table, strict::Bool = true, allow = (),
           llvm_postprocess = mod -> link_runtime!(mod; strict, allow), kwargs...) =
            StaticCompiler.$f(args...; method_table, llvm_postprocess, kwargs...)
        @doc """
            $($f)(args...; method_table = StaticCompilerOverrides.method_table, strict = true, allow = (), kwargs...)

        `StaticCompiler.$($f)`, using the method table of StaticCompilerOverrides by default, and with its
        runtime (allocation, exceptions, ...) added to the code that is generated.

        By default (`strict = true`) the code is rejected with an [`UnsupportedCodeError`](@ref) if
        it contains something that can't work in a standalone binary: calls that need the Julia runtime
        (most often, dynamic dispatch), or references to Julia objects by their address. `strict = false`
        compiles it anyway, with calls that need the runtime aborting the program if they are reached.
        `allow` is a collection of names of runtime functions (as in the error message) to accept even
        in strict mode.
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
