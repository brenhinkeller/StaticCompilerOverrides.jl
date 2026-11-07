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
using .Runtime: link_runtime!

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
        $f(args...; method_table = method_table, llvm_postprocess = link_runtime!, kwargs...) =
            StaticCompiler.$f(args...; method_table, llvm_postprocess, kwargs...)
        @doc """
            $($f)(args...; method_table = StaticCompilerOverrides.method_table, llvm_postprocess = link_runtime!, kwargs...)

        `StaticCompiler.$($f)`, using the method table of StaticCompilerOverrides by default, and with its
        runtime (allocation, exceptions, ...) added to the code that is generated.
        """ $f
    end
end
