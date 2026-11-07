# StaticCompilerOverrides

[![Docs][docs-dev-img]][docs-dev-url]
[![CI][ci-img]][ci-url]
[![Coverage][codecov-img]][codecov-url]

Device overrides and other such glue to enable as much Julia code as possible to be compiled to standalone binaries, 
using [StaticCompiler.jl](https://github.com/tshort/StaticCompiler.jl) and to some extent [StaticTools.jl](https://github.com/brenhinkeller/StaticTools.jl). Highly experimental.

The code and documentation in this package is (unlike StaticCompiler and StaticTools) almost entirely LLM-generated, 
specifically via Claude code running Sonnet 5.5. I'm not yet sure how far we'll be able to get, but it's worth a try.

Currently requires Julia 1.14

## Example

Ordinary Julia code, with arrays, string interpolation, `parse`, and printing of containers, becomes a small
native executable that doesn't need Julia installed:

```julia
using StaticCompilerOverrides

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

exe = compile_executable(main, (Vector{String},), "build", "primes")   # about 175 kB, no libjulia
```

```
$ ./build/primes 30
The 10 primes up to 30: [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
Their mean is 12.9
```

## Status

Allocating code (`Vector`, `Dict`, `String`, ...), `print`/`println`/`show` of numbers, strings, characters, arrays, tuples and types, `printf` and `@printf(STDOUT, ...)`, files (`open`, `read`, `readlines`, ...), reading from the standard input, `rand`, linear algebra (through BLAS, with the library that is in use when compiling), and `try`/`catch` compile to standalone binaries, which also get the arguments of the command line; see `test/corpus.jl` for what is checked, and what is known not to work yet (for instance `show` of matrices).

Code that can't work in a standalone binary is rejected when compiling, with an explanation (`strict = false` to compile it anyway).

**Compiled programs have a garbage collector** (conservative and non-moving, written in Julia and compiled into the program), so memory is freed as in Julia; `gc = false` leaves it out, for programs that don't need it. See the [manual](docs/src/index.md) for how it works and what it can't see.

### Limitations

This works for code whose types the compiler can work out, with the runtime that it needs added. The main limits, which the manual has in full:

* **Dynamic behavior**: dispatch on `Any`, on abstract types with many subtypes, and on types that are only known when the program runs; `eval`; tasks, `Channel`s and threads; non-`const` globals. Dispatch on an abstract type with up to 16 concrete subtypes does work.
* **Libraries that aren't in the binary**: no `BigInt`, `BigFloat` or `Regex`; BLAS and LAPACK need libblastrampoline and the library behind it at the same paths when the program is run.
* **Platforms**: macOS and Linux for the collector, and Linux is not tested yet; the machine that compiles is the one that is targeted.
* **Memory**: the collector is conservative and the heap is not thread-safe (a library called from several threads needs a lock; on a stack that is not its thread's it frees nothing).
* **Runtime differences**: at most 256 nested `try` blocks, no stack overflow check (infinite recursion crashes), and uncaught exceptions exit with a short message and no backtrace.

See [Known limitations](https://brenhinkeller.github.io/StaticCompilerOverrides.jl/dev/#Known-limitations) in the manual for the complete list and the reasons.

[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://brenhinkeller.github.io/StaticCompilerOverrides.jl/dev/
[ci-img]: https://github.com/brenhinkeller/StaticCompilerOverrides.jl/workflows/CI/badge.svg
[ci-url]: https://github.com/brenhinkeller/StaticCompilerOverrides.jl/actions/workflows/CI.yml
[codecov-img]: http://codecov.io/github/brenhinkeller/StaticCompilerOverrides.jl/coverage.svg?branch=main
[codecov-url]: http://app.codecov.io/github/brenhinkeller/StaticCompilerOverrides.jl?branch=main
