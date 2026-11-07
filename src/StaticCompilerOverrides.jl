module StaticCompilerOverrides

using Reexport: @reexport
using StaticCompiler: StaticCompiler
# StaticCompiler's own entry points (and `@device_override`) are replaced by ones of ours that
# use our method table, see `overrides.jl`
@reexport using StaticCompiler: StaticTarget
@reexport using StaticTools

include("overrides.jl") # Our method table, `@device_override`, and the entry points that use it

include("tags.jl")     # The type tags of objects
include("base.jl")     # Base methods that can be written to compile statically
include("io.jl")       # Standard input and output
include("show.jl")     # show of types and containers
include("printf.jl")   # Printf, for formats without `*`
include("unicode.jl")  # Properties of characters, without utf8proc
include("files.jl")     # Files
include("random.jl")   # Random number generation without tasks
include("testing.jl")  # Differential testing: compiled executable vs. ordinary Julia

export compile_executable, compile_shlib, static_code_llvm, static_code_typed, static_code_native,
       static_llvm_module, @device_override
export UnsupportedCodeError, add_show_candidates!
export StaticIO, StaticFile, STDIN, STDOUT, STDERR
export static_result, static_status, undefined_symbols, allocation_sites, @static_test

end # module StaticCompilerOverrides
