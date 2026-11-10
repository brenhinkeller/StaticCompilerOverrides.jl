# The tests of the compiler, the runtime and the language, in the order that things depend on each other.

# strict mode, method tables, and the entry points that are not accepted; the functions that test a program
include_timed("strict.jl")
include_timed("harness.jl")

# what goes into the binary: constants, objects, types and their tags
include_timed("embedding.jl")
include_timed("embedfuzz.jl")
include_timed("tags.jl")
include_timed("subtype.jl")
include_timed("objectid.jl")

# the runtime: allocation, the collector and its finalizers, exceptions, the entry point and the files
include_timed("runtime.jl")
include_timed("heap.jl")
include_timed("finalizers.jl")
include_timed("exceptions.jl")
include_timed("filesystem.jl")

# dynamic dispatch, closures and C callbacks
include_timed("dispatch.jl")
include_timed("closures.jl")
include_timed("cfunctions.jl")

# the language and Base
include_timed("language.jl")
include_timed("containers.jl")
include_timed("idioms.jl")
include_timed("symbols.jl")
include_timed("globals.jl")
include_timed("tuples.jl")
include_timed("random.jl")
include_timed("unicode.jl")

# printing
include_timed("printing.jl")
include_timed("show.jl")
include_timed("arrays.jl")
include_timed("plain.jl")

# libraries that the program calls, and what it is not allowed to do quietly
include_timed("libraries.jl")
include_timed("silent.jl")
