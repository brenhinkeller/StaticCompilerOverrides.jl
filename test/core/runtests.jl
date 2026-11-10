# The tests of the compiler, the runtime and the language, in the order that things depend on each other.
@info "Core tests:"

# strict mode, method tables, and the entry points that are not accepted; the functions that test a program
@testset verbose=true "Internals" begin
    include_timed("strict.jl")
    @testset verbose=true "Harness" include_timed("harness.jl")
end

# what goes into the binary: constants, objects, types and their tags
@testset verbose=true "Embedding" begin
    include_timed("embedding.jl")
    include_timed("embedfuzz.jl")
end
@testset verbose=true "Tags" include_timed("tags.jl")
@testset verbose=true "Subtype" include_timed("subtype.jl")
@testset verbose=true "ObjectID" include_timed("objectid.jl")

# the runtime: memory and the collector, exceptions, the executable, files and the operating system
@testset verbose=true "Runtime" begin
    @testset verbose=true "Heap" include_timed("heap.jl")
    include_timed("finalizers.jl")
    @testset verbose=true "Exceptions" include_timed("exceptions.jl")
    @testset verbose=true "Default Entry" include_timed("executables.jl")
    @testset verbose=true "Files" include_timed("files.jl")
    @testset verbose=true "System" include_timed("system.jl")
end

# dynamic dispatch, closures and C callbacks
@testset verbose=true "Dispatch" include_timed("dispatch.jl")
@testset verbose=true "Closures" include_timed("closures.jl")
@testset verbose=true "CFunction" include_timed("cfunctions.jl")

# the language and Base: values, numbers, strings, collections, symbols, globals
@testset verbose=true "Language" include_timed("language.jl")
@testset verbose=true "Numbers" include_timed("numbers.jl")
@testset verbose=true "Strings" include_timed("strings.jl")
@testset verbose=true "Containers" include_timed("containers.jl")
@testset verbose=true "Tuples" include_timed("tuples.jl")
@testset verbose=true "Symbols" include_timed("symbols.jl")
@testset verbose=true "Globals" include_timed("globals.jl")
@testset verbose=true "Random" include_timed("random.jl")

# printing
@testset verbose=true "Printing" begin
    include_timed("printing.jl")
    include_timed("show.jl")
    include_timed("arrays.jl")
    include_timed("plain.jl")
end

# libraries that the program calls
@testset verbose=true "Libraries" include_timed("libraries.jl")

# what is not supported, and what happens then
@testset verbose=true "Limitations" include_timed("limitations.jl")
