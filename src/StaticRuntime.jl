module StaticRuntime

using Reexport: @reexport
using StaticCompiler: StaticCompiler
using GPUCompiler: GPUCompiler
using LLVM: LLVM
# StaticCompiler's own entry points (and `@device_override`) are replaced by ones of ours that
# use our method table, see `overrides.jl`
@reexport using StaticCompiler: StaticTarget
@reexport using StaticTools

# The compiler: our method table and entry points, the type tags and the pipeline of LLVM passes
include("overrides.jl") # Our method table, `@device_override`, and the entry points that use it
include("tags.jl")      # The type tags of objects
include("pipeline.jl")  # The LLVM pipeline of our compilations: vectorizers, tags

# The overrides of Base that make what it does compile, by what they are for
include("overrides/base.jl")       # Base methods that can be written to compile statically
include("overrides/io.jl")         # Standard input and output
include("overrides/context.jl")    # IOContext: streams with properties known when compiling
include("overrides/show.jl")       # show of types and containers
include("overrides/color.jl")      # printstyled and the colors of text
include("overrides/printf.jl")     # Printf, for formats without `*`
include("overrides/unicode.jl")    # Properties of characters, without utf8proc
include("overrides/symbols.jl")    # Symbols that are made when the program runs
include("overrides/objectid.jl")   # objectid, so that a struct can be the key of a Dict
include("overrides/iddict.jl")     # IdDict, and with it deepcopy
include("overrides/dict.jl")       # Dicts made of pairs of different types
include("overrides/deepcopy.jl")   # deepcopy of any struct
include("overrides/bignum.jl")     # BigInt and BigFloat
include("overrides/regex.jl")      # Regex
include("overrides/files.jl")      # Files
include("overrides/filesystem.jl") # The file system, the environment, the process
include("overrides/random.jl")     # Random number generation without tasks
include("overrides/logging.jl")    # @warn, @info and @error, to the standard error
include("overrides/gc.jl")         # The garbage collector, from the program
include("overrides/finalizers.jl") # finalizer(f, x) of a Julia function

# Inference: what the compiler does with calls that are not resolved by Julia
include("inference/dispatch.jl")    # dynamic dispatch on abstract types, by union splitting
include("inference/closures.jl")    # calls of functions that are not known: closures in collections, in boxes
include("inference/cfunctions.jl")  # @cfunction: C functions that call functions of the program
include("inference/diagnostics.jl") # Why an entry point does not infer to a concrete type

# Testing programs: differential testing against Julia, and what the code of a program needs
include("testing.jl")    # Differential testing: compiled executable vs. ordinary Julia

export compile_executable, compile_shlib, static_code_llvm, static_code_typed, static_code_native,
       static_llvm_module, @device_override
export UnsupportedCodeError, InferenceError, add_show_candidates!, add_dispatch_candidates!
export StaticIO, StaticFile, STDIN, STDOUT, STDERR
export static_result, static_status, static_status_batch, undefined_symbols, allocation_sites, @static_test
export gc_live_bytes, gc_collections, gc_heap_bytes

end # module StaticRuntime
