# StaticCompilerOverrides

[![Docs][docs-dev-img]][docs-dev-url]
[![CI][ci-img]][ci-url]
[![Coverage][codecov-img]][codecov-url]

Device overrides and other such glue to enable as much Julia code as possible to be compiled to standalone binaries as possible, using StaticCompiler.jl + StaticTools.jl.

The code in this package is (unlike StaticCompiler.jl and StaticTools.jl themselves) almost entirely LLM-generated, 
specifically via Claude code running Sonnet 5.5. I'm not yet sure how far we'll be able to get, but it's worth a try.


## Status

Allocating code (`Vector`, `Dict`, `String`, ...), `rand`, and `try`/`catch` compile to standalone binaries; see `test/corpus.jl` for what is checked.

**Compiled programs have no garbage collector: heap allocations are never freed.** This is fine for short-running programs, but a program that allocates in a loop grows without bound. See the [manual](docs/src/index.md) for what leaks and how to avoid it.

Requires Julia 1.14.

[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://brenhinkeller.github.io/StaticCompilerOverrides.jl/dev/
[ci-img]: https://github.com/brenhinkeller/StaticCompilerOverrides.jl/workflows/CI/badge.svg
[ci-url]: https://github.com/brenhinkeller/StaticCompilerOverrides.jl/actions/workflows/CI.yml
[codecov-img]: http://codecov.io/github/brenhinkeller/StaticCompilerOverrides.jl/coverage.svg?branch=main
[codecov-url]: http://app.codecov.io/github/brenhinkeller/StaticCompilerOverrides.jl?branch=main