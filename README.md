# StaticCompilerOverrides

[![Docs][docs-dev-img]][docs-dev-url]
[![CI][ci-img]][ci-url]
[![Coverage][codecov-img]][codecov-url]

Device overrides and other such glue to enable as much Julia code as possible to be compiled to standalone binaries as possible, using StaticCompiler.jl + StaticTools.jl.

The code and documentation in this package is (unlike StaticCompiler.jl and StaticTools.jl) almost entirely LLM-generated, 
specifically via Claude code running Sonnet 5.5. I'm not yet sure how far we'll be able to get, but it's worth a try.


## Status

Allocating code (`Vector`, `Dict`, `String`, ...), `print`/`println`/`show` of numbers, strings and characters, `printf` and `@printf(STDOUT, ...)`, files (`open`, `read`, `readlines`, ...), reading from the standard input, `rand`, and `try`/`catch` compile to standalone binaries, which also get the arguments of the command line; see `test/corpus.jl` for what is checked, and what is known not to work yet (for instance `show` of arrays and tuples).

Code that can't work in a standalone binary is rejected when compiling, with an explanation (`strict = false` to compile it anyway).

**Compiled programs have no garbage collector: heap allocations are never freed.** This is fine for short-running programs, but a program that allocates in a loop grows without bound. See the [manual](docs/src/index.md) for what leaks and how to avoid it.

Requires Julia 1.14.
