module StaticCompilerOverrides

using Reexport: @reexport
using StaticCompiler: StaticCompiler
using GPUCompiler: GPUCompiler
using LLVM: LLVM
# StaticCompiler's own entry points (and `@device_override`) are replaced by ones of ours that
# use our method table, see `overrides.jl`
@reexport using StaticCompiler: StaticTarget
@reexport using StaticTools

include("overrides.jl") # Our method table, `@device_override`, and the entry points that use it

include("tags.jl")     # The type tags of objects
include("base.jl")     # Base methods that can be written to compile statically
include("io.jl")       # Standard input and output
include("context.jl")  # IOContext: streams with properties known when compiling
include("show.jl")     # show of types and containers
include("objectid.jl") # objectid, so that a struct can be the key of a Dict
include("symbols.jl")  # Symbols that are made when the program runs
include("iddict.jl")   # IdDict, and with it deepcopy
include("dict.jl")     # Dicts made of pairs of different types
include("deepcopy.jl") # deepcopy of any struct
include("bignum.jl")   # BigInt and BigFloat
include("regex.jl")    # Regex
include("dispatch.jl") # dynamic dispatch on abstract types, by union splitting
include("diagnostics.jl") # Why an entry point does not infer to a concrete type
include("gc.jl")       # The garbage collector, from the program
include("finalizers.jl") # finalizer(f, x) of a Julia function
include("printf.jl")   # Printf, for formats without `*`
include("unicode.jl")  # Properties of characters, without utf8proc
include("files.jl")     # Files
include("filesystem.jl") # The file system, the environment, the process
include("random.jl")   # Random number generation without tasks
include("logging.jl")  # @warn, @info and @error, to the standard error
include("testing.jl")  # Differential testing: compiled executable vs. ordinary Julia

export compile_executable, compile_shlib, static_code_llvm, static_code_typed, static_code_native,
       static_llvm_module, @device_override
export UnsupportedCodeError, InferenceError, add_show_candidates!, add_dispatch_candidates!
export StaticIO, StaticFile, STDIN, STDOUT, STDERR
export static_result, static_status, undefined_symbols, allocation_sites, @static_test
export gc_live_bytes, gc_collections, gc_heap_bytes

end # module StaticCompilerOverrides
