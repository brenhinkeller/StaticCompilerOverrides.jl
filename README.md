# StaticCompilerOverrides

[![Docs][docs-dev-img]][docs-dev-url]
[![CI][ci-img]][ci-url]
[![Coverage][codecov-img]][codecov-url]

Device overrides and other such glue to enable as much Julia code as possible to be compiled to standalone binaries as possible, using [StaticCompiler.jl](https://github.com/tshort/StaticCompiler.jl) and to some extent [StaticTools.jl](https://github.com/brenhinkeller/StaticTools.jl). Highly experimental.

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

Allocating code (`Vector`, `Dict`, `String`, ...), `print`/`println`/`show` of numbers, strings, characters, arrays, tuples and types, `printf` and `@printf(STDOUT, ...)`, files (`open`, `read`, `readlines`, ...), reading from the standard input, `rand`, and `try`/`catch` compile to standalone binaries, which also get the arguments of the command line; see `test/corpus.jl` for what is checked, and what is known not to work yet (for instance `show` of dictionaries and `Matrix`).

Code that can't work in a standalone binary is rejected when compiling, with an explanation (`strict = false` to compile it anyway).

**Compiled programs have no garbage collector: heap allocations are never freed.** This is fine for short-running programs, but a program that allocates in a loop grows without bound. See the [manual](docs/src/index.md) for what leaks and how to avoid it.
