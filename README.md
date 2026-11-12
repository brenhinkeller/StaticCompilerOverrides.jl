# StaticRuntime

[![Docs][docs-dev-img]][docs-dev-url]
[![CI][ci-img]][ci-url]
[![Coverage][codecov-img]][codecov-url]

This experimental package attempts to allow the compilation of as much generic Julia code as possible into a single binary, without requiring `libjulia`, using [StaticCompiler.jl](https://github.com/tshort/StaticCompiler.jl) (and in turn [GPUCompiler.jl](https://github.com/JuliaGPU/GPUCompiler.jl)), and to a lesser extent [StaticTools.jl](https://github.com/brenhinkeller/StaticTools.jl). 

The approach invloves (1) liberal use of `@device_override` (as in StaticCompiler, but defined again here so as to not pollute the default StaticCompiler method table) to avoid un-StaticCompiler-able code, (2) some custom GPUCompiler params and LLVM IR transformations, and (3) a minimal runtime, including a small optional garbage collector (written in pure Julia), linkers, IO handling, and anything else we need to compile into the binary.

The code and documentation in this package is (unlike StaticCompiler and StaticTools) almost entirely LLM-generated, 
specifically via Claude code running Sonnet 5.5. I'm not yet sure how far we'll be able to get, but it's worth a try.

Currently targets Julia 1.14

## Examples

Ordinary Julia code, with arrays, string interpolation, `parse`, and printing of containers, becomes a small
native executable that doesn't need Julia installed:

```julia
using StaticRuntime

# A sieve of Eratosthenes, with the limit from the command line
function main(args::Vector{String})
    n = length(args) > 0 ? parse(Int, args[1]) : 50
    sieve = fill(true, n)
    sieve[1] = false
    for i in 2:isqrt(n), j in i*i:i:n
        sieve[j] = false
    end
    primes = findall(sieve)
    println("The $(length(primes)) primes up to $n: ", primes)
    println("Their mean is ", sum(primes) / length(primes))
    return 0
end

compile_executable(main, (Vector{String},), "build", "primes"; small=true)
```

```
shell> ls -logh build
total 568
-rwxr-xr-x  1    115K Nov 12 11:04 primes
-rw-r--r--  1    168K Nov 12 11:04 primes.o

shell> ./build/primes 30
The 10 primes up to 30: [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
Their mean is 12.9
```

The entry point used in the example above is `main(args)`, though `main()` is also an option for a program with no arguments, as is a C-style `main(argc, argv)` (`(Int, Ptr{Ptr{UInt8}})`, which must return an integer); see [Entry points](docs/src/index.md).

If not otherwise specified, the garbage collector will be included only if it is thought to be needed (`gc = :auto`, the default). This includes the GC for anything that allocates repeatedly in a loop or other cycle (not counting error paths), and excludes it otherwise. Alternatively, a program compiled with `gc = true` always has one, and with `gc = false` never does. Meanwhile, the `small = true` option attempts to make the file smaller where possible (no names of functions or segment of constants in the file). A small program is then a few tens of kilobytes, depending on architecture (see [Binary size](docs/src/index.md)).

### More advanced examples

Big numbers and regular expressions are some of the Julia base features that currently rely on external libraries (GMP, MPFR, and PCRE2). These will continue to work in compiled Julia code, linking against the same libraries; `libraries = :bundle` copies those libraries next to the program, so that the folder can be moved:

```julia
function bignums(args::Vector{String})
    n = length(args) > 0 ? parse(Int, args[1]) : 1
    println("$(n)! = ", factorial(big(n)))                      # BigInt (GMP)
    println("sqrt($n) = ", sqrt(big(n)))                        # BigFloat (MPFR), 256 bits
    return 0
end

compile_executable(bignums, (Vector{String},), "build"; libraries = :bundle)
```

```
shell> tree --du -h build
[1.5M]  build
├── [207K]  bignums
├── [266K]  bignums.o
└── [1016K]  lib
    ├── [490K]  libgmp.10.dylib
    └── [526K]  libmpfr.6.dylib

 1.5M used in 2 directories, 4 files

shell> ./build/bignums 42
42! = 1405006117752879898543142606244511569936384000000000
sqrt(42) = 6.480740698407860230965967436087996657705204307058346549711354397809617377844025
```

Heterogeneous data, dictionaries of symbols, structs and matrices print as they do in Julia (here, through the static `IOContext` and `text/plain` machinery), and the garbage collector frees what the program no longer uses:

```julia
using LinearAlgebra

struct Sample; name::Symbol; values::Vector{Float64}; end

function main(args::Vector{String})
    samples = [Sample(:a, randn(1000)), Sample(:b, 2 .+ randn(1000))]
    stats = Dict(s.name => (sum(s.values) / length(s.values), maximum(s.values)) for s in samples)
    println(stats)                                  # Dict(:a => (0.0019, 2.88), :b => (1.98, 5.38))
    A = [s.values[i] for i in 1:3, s in samples]
    display(A' * A)                                 # a 2x2 Matrix{Float64}, through BLAS
    return 0
end

compile_executable(main, (Vector{String},), "build", "stats")
```

A function of any library can be called with `ccall`; it is looked up when the program runs (here zlib's checksum, through its JLL):

```julia
using Zlib_jll
crc(s::String) = ccall((:crc32, Zlib_jll.libz), Culong, (Culong, Ptr{UInt8}, Cuint), 0, pointer(s), sizeof(s))

main(args::Vector{String}) = (println(crc(get(args, 1, "hello"))); 0)

compile_executable(main, (Vector{String},), "build", "crc")
```

## Status

What compiles to a standalone binary (the arguments of the command line included), and is checked against Julia in the tests:

* **The language and Base**: allocating code (`Vector`, `Dict` including mixed key and value types, `Set`, `String`, `Symbol` including `Symbol(string)` made at run time, structs, tuples, fields of a `Union{Node,Nothing}`), closures (also stored in collections and called through them), `@cfunction` callbacks (`qsort`, `bsearch`, ...), `try`/`catch`/`finally`, non-`const` global variables, `deepcopy`, `IdDict`, `rand` and `RandomDevice`, files and the standard input, and logging (`@warn` and friends).
* **Printing**: `print`, `println`, `show`, `display` and `text/plain` of numbers, strings, symbols, containers, structs, tuples and matrices, with `IOContext` properties known when compiling; `printf` and `@printf(STDOUT, ...)`.
* **Filesystem**: `stat`, `mkdir`, `rm`, `readdir`, `cp`, `mv`, and temporary files.
* **Dynamic dispatch**: calls on `Any` and abstract types are closed over a list of registered types, so they compile (and are exact for abstract types with few concrete subtypes).
* **Libraries**: BLAS and LAPACK (through libblastrampoline), `BigInt`, `BigFloat`, `Regex`, SuiteSparse (sparse `\`, `lu`, `cholesky`, `qr`), **MPI** (MPI.jl programs run under `mpiexec`), any JLL or library of your own through `ccall`, with `libraries = :system` or `:bundle`; and `finalizer(f, x)` frees what they allocate.
* **Standard libraries**: `Base64`, `CRC32c`, `LinearAlgebra` (including `schur`, `sqrt` and `log` of matrices), `Mmap` (of files by their path), `Printf`, `Random`, `SHA`, `Statistics`, `UUIDs` (including `uuid4()`), the address types of `Sockets`, and most of `Dates` and `SparseArrays`.
* **Packages**: code from other packages compiles like Base's. The standard libraries and these packages are a survey kept as tests (`test/packages`), with the cases that don't work listed in the manual: DataStructures.jl, Distributions.jl, Graphs.jl, NaNStatistics.jl, OrderedCollections.jl, Parsers.jl, StatsBase.jl, StaticArrays.jl and MPI.jl.

`test/` is the up-to-date list of what is checked, and `test/core/limitations.jl` of what is refused, and what happens then.

Code that we know can't work in a standalone binary is rejected when compiling, with an explanation (one can set `strict = false` to compile it anyway, though this is not recommended).

### How it works

* **An overlay method table** (`@device_override`) replaces the methods of Base that can't be compiled (they use tasks, locks, libuv, `inferencebarrier`, ...) with ones that can.
* **A runtime written for compiled programs** is linked into the code: allocation, exceptions, boxing, type tags and the like. Julia objects that the code uses as constants (strings, arrays, `Ref`s, types, symbols, non-`const` globals) are copied into the binary, with their type information, so no libjulia is needed.
* **A garbage collector** (conservative, non-moving, mark and sweep, written in Julia and compiled into the program) frees memory as Julia does, and runs the C finalizers of libraries (e.g., GMP's). It is only in the programs that need it (`gc = :auto`); `gc = true` and `gc = false` always and never include it. See the [manual](docs/src/index.md) for how it works and what it can't see.
* **A loader for libraries** looks functions up the first time that they are called (`dlopen`, `dlsym`), after the libraries that they need, and can find them in a `lib` folder next to the program.
* **Inference is helped along in some cases**: calls on abstract values are made over registered types, calls of functions that are not known (a closure taken out of a collection) over the closures that the program has, `@cfunction` callbacks are given a target that is compiled, tuples that have a `Union` as an element are favored for inlining, and keyword and context arguments propagate as constants so that code like `IOContext(io, :compact => true)` compiles.
* **Checks for silent wrong results**: what would differ from Julia is refused when compiling (for instance constant tables hashed by address), and numbers are never mistaken for addresses.

### Limitations

The main limits, which the manual has in full:

* **Dynamic behavior**: a value of an unregistered type aborts the program when it reaches a dispatch over registered types (compiling says what it did this way, with `JULIA_DEBUG=StaticRuntime`; `add_dispatch_candidates!` adds types). Not supported: types that are only known when the program runs and can't be listed, `eval`, tasks, `Channel`s and threads, and a tuple that has a `Union` as an element and is not removed by inlining (one that a function that is not inlined returns, or that is stored in a collection).
* **Libraries of Julia that are not libraries of their own**: `Markdown` (its parser needs Julia's), `TOML.parse`, `Unicode.normalize` and `graphemes` (utf8proc), `@time` and `Test`.
* **Libraries**: by default a program needs its libraries at the paths that they had when compiling (`libraries = :bundle` copies them next to the program; BLAS is not bundled yet). `atexit` functions are not run, and a reduction in MPI with an operator of your own (a C callback into Julia) is not supported.
* **Platforms**: macOS and Linux for the collector; the machine that compiles is the one that is targeted (no cross-compiling, no Windows). Linux is tested in CI (x86 and aarch64), and the libraries there are the least tested.
* **Memory**: the collector is conservative and the heap is not thread-safe (a library called from several threads needs a lock; on a stack that is not its thread's it frees nothing).
* **Runtime differences**: at most 256 nested `try` blocks, no stack overflow check (infinite recursion crashes), and uncaught exceptions exit with a short message and no backtrace.

See [Known limitations](https://brenhinkeller.github.io/StaticRuntime.jl/dev/#Known-limitations) in the manual for the complete list and the reasons.

### Source layout

* `src/overrides/`: the overlay methods of Base and of the standard libraries, by topic (`show.jl`, `files.jl`, `random.jl`, `bignum.jl`, ...); `src/overrides.jl` is the method table and the entry points (`compile_executable` and the rest).
* `src/inference/`: what the compiler does with calls that Julia does not resolve: dynamic dispatch (`dispatch.jl`), closures (`closures.jl`), `@cfunction` (`cfunctions.jl`) and the errors that say why a program does not infer (`diagnostics.jl`).
* `src/runtime/`: the runtime that is linked into a program: the allocator and collector (`heap.jl`, `heap_link.jl`), the objects that are copied into the binary (`objects.jl`, `embedder.jl`, `constants.jl`), types at run time (`types.jl`), what is refused (`strict.jl`), and BLAS and the loader of libraries.
* `src/pipeline.jl` and `src/tags.jl`: the LLVM passes; `src/testing.jl`: `static_status` and the other functions that compare a compiled program with Julia.
* `ext/`: the overlays that need another package or standard library (LinearAlgebra, SparseArrays, Dates, Base64, Mmap, MPI).

### Running the tests

`] test` runs all: the tests of the compiler, the runtime and the language (`test/core`), as well as those of the standard libraries and the packages that programs use (`test/packages`).
Most of them compile a program and compare what it prints with what Julia prints for the same code. Set `GROUP=Core` or `GROUP=Packages` to run one of the two, `PACKAGES=Dates,MPI` to run some of the files of `Packages` (the MPI tests need an MPI library, which MPI.jl installs), `TEST_TIMING=1` to print the time that each file took, and `TEST_FOLDED=1` to fail the cases whose program is only a print of an answer that the compiler found (`opaque` in `test/helpers.jl` makes values that it does not know). `STATIC_RUNTIME_GC=3` runs the programs with the collector in stress mode, sweeping every three allocations.

[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://brenhinkeller.github.io/StaticRuntime.jl/dev/
[ci-img]: https://github.com/brenhinkeller/StaticRuntime.jl/workflows/CI/badge.svg
[ci-url]: https://github.com/brenhinkeller/StaticRuntime.jl/actions/workflows/CI.yml
[codecov-img]: http://codecov.io/github/brenhinkeller/StaticRuntime.jl/coverage.svg?branch=main
[codecov-url]: http://app.codecov.io/github/brenhinkeller/StaticRuntime.jl?branch=main
