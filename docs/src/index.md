```@meta
CurrentModule = StaticCompilerOverrides
```

# StaticCompilerOverrides

Glue between [StaticCompiler.jl](https://github.com/tshort/StaticCompiler.jl) and
[StaticTools.jl](https://github.com/brenhinkeller/StaticTools.jl), to let as much ordinary Julia
code as possible compile to a standalone executable or shared library that does not depend on
`libjulia`.

```julia
using StaticCompilerOverrides   # also loads (and re-exports) StaticCompiler and StaticTools

function main(argc::Int, argv::Ptr{Ptr{UInt8}})
    v = collect(1:argc+3)       # an ordinary Vector
    printf(c"%d\n", sum(v))
    return 0
end

compile_executable(main, (Int, Ptr{Ptr{UInt8}}))
```

Julia 1.14 or later is required.

## What works

Code that allocates (`Vector`, `Dict`, `Set`, `String`, closures that escape, boxed values),
`print`/`println`/`show` of numbers, strings, characters, symbols, arrays, tuples, pairs and types, `readline` and friends,
`rand`/`randn` on the default RNG, and `try`/`catch`/`finally`/`rethrow` (including for errors thrown by Base, like `BoundsError`), in addition to what
StaticCompiler already handled (allocation-free numerical code, StaticTools types, and so on).
The tests in `test/corpus.jl` are the up-to-date list of the idioms that we check, and which of
them are known not to work yet.

See [Input and output](@ref) for printing and reading, and [Entry points](@ref) for how to get the
arguments of the command line.

## Input and output

The standard streams of Julia are libuv streams, which need the Julia runtime. Compiled programs
use those of libc, as [`StaticIO`](@ref)s: [`STDIN`](@ref), [`STDOUT`](@ref) and [`STDERR`](@ref).
`StaticIO` implements the `IO` interface, so all of the code of Base for printing and reading works
with it (`print`, `show`, `write`, `read`, `readline`, `eof`, `flush`, ...).

`print`, `println` and `show` without an `IO` write to the standard output, as in Julia:

```julia
function main(args::Vector{String})
    println("Hello, ", isempty(args) ? "world" : args[1], "! ", 1 + 1, " ", 2.5, " ", 'λ', " ", :sym)
    println(STDERR, "this goes to the standard error")
    line = readline(STDIN)
    @show line
end
```

!!! warning "`stdout`, `stderr` and `stdin` of Base can't be used: use `STDOUT`, `STDERR` and `STDIN`"
    In Julia, `stdout` is a global variable of the abstract type `IO`, so a call like
    `println(stdout, x)` can only be resolved when it is run, and a compiled program can't do that.
    It is rejected when compiling (see strict mode), with a message that says what to use instead. Code
    that uses `stdout` will work if it is written in a way that doesn't (`println(x)`, or `STDOUT`).

### Formatted output: `printf` and `@printf`

Two ways, which write the same bytes into the same buffer, so can be mixed freely with `print`:

* **`printf` of StaticTools**: C's `printf`, with any number of arguments and a `c"..."` format. Its format
  specifiers are those of C: for example an `Int64` is `%lld` (`%d` is for a 32-bit `int`).
  It takes integers, floating-point numbers, pointers, and strings (`StaticString`s,
  `MallocString`s and `String`s) for `%s`, and a stream first: `printf(STDERR, c"...", x)`.
* **`Printf` of Julia**: `@sprintf` and `@printf(STDOUT, "...", x)` (or `STDERR`, or a file), with Julia's
  own formats, which are the same as in Julia: `%d` is for any integer, and so on. This is Julia's `Printf`,
  so what it writes is the same. A format with `*` (`%*d`) is not supported. The format has to be
  made once, as `@printf` does: a `Printf.Format("...")` made when the program runs can't be compiled.

```julia
printf(c"%s: %d of %lld, %5.2f%%\n", c"progress", 3, 10^12, 12.345)   # C
Printf.@printf(STDOUT, "%s: %d of %d, %5.2f%%\n", "progress", 3, 10^12, 12.345)   # Julia
name = Printf.@sprintf("%s-%03d.txt", "run", 7)
```

### Files

`open` opens a file with libc's `fopen`, as a [`StaticFile`](@ref), which is an `IO` like the standard streams,
so what Base has for reading and writing an `IO` works: `open(f, path, mode)`, `read(path, String)`,
`readlines`, `eachline`, `readline`, `write(path, x, y)`, `println(io, x)`, `eof`, `position`, `seek`,
`filesize`, `close`, `@printf(io, ...)`, `printf(io, c"...", x)`, and numbers and arrays of numbers as binary data
(`write(io, x)`, `read(io, Int32)`, `read!(io, array)`, `read(io, n)`). The mode is the one of `fopen` (`"r"`, `"w"`, `"a"`,
`"r+"`, ...). The keyword arguments of `open`, `readline` and `eachline` (`read = true`, `keep = true`)
are not supported; and so far there is nothing for the file system itself (`isfile`, `mkdir`, `rm`, `readdir`, ...).

### What works, and what doesn't

What works: numbers, strings, characters, symbols, `nothing`, `missing`, and anything built from
those by `string`, interpolation, `sprint`, `repr`, `@show`... and their `show` (with the quotes
and escapes), **arrays** (also nested, and of `Any`), **tuples**, **pairs**, **dictionaries**, **sets**, **types** and plain **structs**
(see [`show` of containers, types and structs](@ref)), Unicode text and its properties (`isletter`, `uppercase`,
`textwidth`, ...), formatting, and files.

What doesn't work yet:
* `show` of matrices (`Matrix`, which also needs BLAS), and of containers that are not arrays, tuples, pairs,
  dictionaries or sets. (Print the elements.)
* **`Dict{K,Any}` or `Dict{Any,Any}` built from pairs** (`Dict{String,Any}("a" => 1)`), and iterating a `Pair` of two
  different types (`for x in "a" => 1`): both are dynamic. Fill a `Dict{K,Any}()` with `d[k] = v`.
* **`===`, and so `Dict`/`Set` lookups, of objects other than `String`s and the same object** (a key that is a
  tuple of Strings, for instance) report and exit when run: the comparison of the contents of a struct needs the
  layout of its type. Keys that are numbers, symbols and Strings are fine.
* **`@printf` without an `io`**, which uses `stdout`: write `@printf(STDOUT, ...)`.
* The **file system** (`isfile`, `mkdir`, `readdir`, `rm`, ...). (`filesize(path)` works.) And memory-mapped
  files, sockets, processes.

The tables for the properties of characters are made when the package is compiled, with the Unicode
data of the Julia that compiles it, and so are the same as in Julia.

### `show` of containers, types and structs

Base's `show` for a container asks the `IOContext` of the stream what is known about the types of the
elements (an `ImmutableDict` of `Any`s), and writes type names by looking up modules and bindings: all
dynamic. Here the same output is made with what is known when compiling (`src/show.jl`):

* the name of a type is a constant string made by Base's own `show` when compiling, so it is what Base prints;
* what the context knows about the type of the elements is in the type of the stream (`TypeInfoIO{T}`), and
  what Base's `typeinfo_prefix` does with it is done when compiling, for the type of the container;
* an element of an abstract type (an element of a `Vector{Any}`, a field of a struct of type `Any`) is shown by
  a chain of `isa` over a closed set of types: the numbers, `String`, `Char`, `Symbol`, `Nothing`,
  `Missing`, `Vector{Any}`, and those you add with [`add_show_candidates!`](@ref). Showing a value of another
  type is an error *when the program runs* (the message says so).

```julia
struct Point; x::Int; y::Float64; end
add_show_candidates!(Point, Tuple{Int,Float64})   # before compiling

main() = (println(Any[1, "a", Point(2, 3.5), (4, 5.0)]); 0)
# Any[1, "a", Point(2, 3.5), (4, 5.0)]
```

Limits: what is shown is not cut (`:limit`) and containers that contain themselves are not detected; a
`Symbol` that is not a plain ASCII identifier (an operator, say) is an error; and the names of types of modules other
than `Main` that the program makes visible with `using`/`import` are written with their module (Base writes
`Main`'s view of them).

## Entry points

`compile_executable(f, (Int, Ptr{Ptr{UInt8}}))` compiles `f(argc, argv)` to the `main` of a C program. For
a program written like a Julia script, `(Vector{String},)` compiles `f(args)`, which gets the arguments
of the command line like `ARGS` (which is also set), and the status of the program is its return value,
if that is an integer. See [`compile_executable`](@ref).

```julia
main(args) = (println("got ", length(args), " arguments"); length(args))
compile_executable(main, (Vector{String},))    # `./main a b c` prints "got 3 arguments" and exits with 3
```

## Writing overrides

`@device_override` adds a method to the method table of this package (see below), which replaces
the method of Base for the code that is compiled. One thing to know: **an override is used for every
call that it covers entirely, instead of all of the methods of Base, including those that are more
specific than it.** So an override `print(x1, x2) = print(STDOUT, x1, x2)` would also be used for
`print(io, x)`, which must go to the methods of Base for printing to an `IO`: `print(io, 'c')`,
`print(io, "string")`... Overrides therefore need to be written so that they don't cover calls that
they should not: with the same signature as the method that they replace, with restricted argument
types, or by doing for those calls what the method of Base does (see `src/io.jl`).

## Strict mode: unsupported code is rejected when compiling

A lot of Julia code can't work in a standalone binary because it needs the Julia runtime: most
often *dynamic dispatch* (a call whose argument types are not known when compiling), but also
anything that refers to a Julia object by its address in the compiling process. Left alone, such
code compiles and links, and then crashes (or, worse, misbehaves) when it is run. So by default
(`strict = true`) the functions of this package reject it when compiling, naming what is wrong:

```julia
julia> compile_executable(main_that_prints, (Int, Ptr{Ptr{UInt8}}))
ERROR: UnsupportedCodeError: the code cannot run as a standalone binary

It needs the Julia runtime (e.g. for dynamic dispatch, which means that the types in some call are not known at compile time):
  ijl_apply_generic, called from show, print
  ijl_get_nth_field_checked, called from print

It refers to Julia objects by their address in this process, which are not in the binary:
  in static_main: %stdout.checked = load atomic ptr, ptr inttoptr (i64 5043311736 to ptr), ...
```

The names are those of the functions of the Julia runtime that the code needs, and of the Julia
functions that call them. For a `ccall` into a library that could not be resolved, it says which function.
(`undefined_symbols` lists the same things for a function, without compiling it.)

Often, the code involved is only reached on a path that fails, for instance to build the message
of an error. `strict = false` compiles such code anyway, defining those runtime functions to print
a message and abort if they are ever called (and the addresses will crash the program if used).
`allow = ("function_name", ...)` accepts specific runtime functions, and keeps the check for the rest.
Run with `JULIA_DEBUG=StaticCompilerOverrides` to see which are defined this way.

## Memory: there is no garbage collector, so allocations leak

!!! warning "Compiled programs never free heap memory unless you do it yourself"
    A compiled program has no garbage collector. Everything that Julia would heap-allocate and
    later collect is instead allocated with `calloc`, and **never freed** until the process exits
    and the operating system reclaims it. This is fine for programs that run briefly or allocate a
    bounded amount in total, but a program that allocates in a loop will grow without bound.

What does and does not allocate:

* **Leaks:** every array (`zeros(n)`, `collect(...)`, `[x for ...]`, a broadcast `a .+ b`), every
  `Dict`/`Set`, every `String` built at run time (`string(i)`, `"a" * "b"`, `repr`, ...),
  every escaping closure or mutable struct, every boxed value, and every thrown exception.
* **Growing containers leak their old storage:** `push!` onto a `Vector` allocates a larger buffer
  when it is full and abandons the old one. The total is about twice the final size, and a
  container that is rebuilt in a loop leaks each time.
* **Does not leak:** anything the compiler can keep on the stack or remove, for instance a small
  `Ref` or tuple that does not escape, or an array that is only used locally and that Julia's
  optimizer can eliminate. Isbits structs and `StackArray`s are always on the stack.

For example, this leaks `8 * n` bytes per call, so `10^9` calls leak about 8 GB per element:

```julia
total(n) = sum(collect(1:n))    # allocates a Vector on every call
```

### Finding allocations

[`allocation_sites`](@ref) counts the places in the compiled code of a function that allocate. Zero
means that nothing is allocated. This is an upper bound, since an allocation in a branch that is
never taken (such as the construction of an exception) is counted too.

```julia
julia> allocation_sites(i -> sum(abs2, 1:i), (Int,))
0

julia> allocation_sites(i -> sum(collect(1:i)), (Int,))
2
```

### Avoiding leaks

* Allocate once, outside the loop, and reuse the memory (`resize!`, `fill!`, in-place `.=` and
  `mul!`, `empty!`).
* Prefer `StackArray`s (`StackVector`, `StackMatrix`) from StaticTools for small, fixed-size data.
* For memory with a clear lifetime, use `MallocArray`/`MallocString` from StaticTools and `free`
  them yourself, or `@no_escape`/`@alloc` from Bumper.jl, which release everything allocated in the
  block when it ends.
* Avoid building strings in loops; write with `printf` or `print` directly instead.
* Do not use exceptions for ordinary control flow in a loop: each `throw` leaks the exception.

!!! note
    Freeing is not just unimplemented: Julia code does not say when it is finished with an object,
    so no allocator can free these objects automatically without a garbage collector or reference
    counting. Neither is planned for now. Arena allocation (releasing a whole region at once) is the
    likely first step.

## Exceptions

`try`/`catch`/`finally` and `rethrow` work, as long as the exception was thrown by code in the
same program. They are implemented with `setjmp`/`longjmp` and a fixed-depth handler stack (256
nested `try` blocks).

An exception that no `try` catches prints `fatal: uncaught exception (no handler to catch it)`
and exits with status 1. The message does not say which exception it was.

Limitations, which are bugs rather than design choices:

* `catch e; e isa T` works with concrete types, and with abstract ones for constants (objects have type
  tags, and the types that the code mentions are in the binary; see [Type tags](@ref)). `isa` with an abstract type
  or a `Union` on a *boxed value whose type is only known at run time* needs `jl_subtype`, and is rejected when
  compiling.
* Code that needs dynamic dispatch, or other things from the Julia runtime, is rejected when
  compiling (see strict mode). With `strict = false`, it compiles and aborts with
  `Dynamic behavior is not supported in standalone binaries (...)` if the call is reached.

## Type tags

Every object that a compiled program allocates has a type tag in its header, as in Julia: a small number for
the built-in types and the address of the type object otherwise. `isa` with a concrete type, the type of a caught
exception, and `show` of an `Any` element read this tag. The objects that the code refers to as constants
(strings, tuples, types, ...) are copied into the binary with their tags, and so are the type objects that
the tags and `isa` with abstract types read (names, parameters). Details are in `src/tags.jl` and `src/runtime.jl`.

## Method tables

StaticCompiler replaces methods that can't be compiled using an overlay method table. Its own table
(`StaticCompiler.method_table`) includes overrides of the error helpers of Base (`error`,
`throw_boundserror`, `throw_inexacterror`, integer division by zero, ...) that print a message and
exit, which made sense when compiled code could not throw, but means that those errors cannot be
caught.

A compilation uses exactly one overlay table, with Base itself as the fallback, so this package has
a table of its own, [`StaticCompilerOverrides.method_table`](@ref), which does not contain those
overrides: errors throw, just as in Julia, and `try`/`catch` can catch them. Use the functions of
this package (`compile_executable`, `compile_shlib`, `static_code_llvm`, ...), which are
StaticCompiler's with this table as the default, and `@device_override` to add to it. These
replace the functions of the same name in StaticCompiler, so load only one of the packages
with `using`. To compile with StaticCompiler's table instead, pass
`method_table = StaticCompiler.method_table`.

## Random numbers

`Random.default_rng()` (a `TaskLocalRNG`) keeps its state in the current task, which does not
exist in compiled programs. It is replaced by a global xoshiro256++ state, seeded from the
operating system (`getentropy`) when first used, like Julia seeds a new process. `Random.seed!(rng,
seed)` works for explicitly constructed generators. The default generator is not thread-safe, as
there are no threads. `Random.seed!(seed)` on the default generator does not work yet.

## Testing that something compiles

```julia
julia> using StaticCompilerOverrides

julia> @static_test sum(rand(10)) < 10     # compile, run, and compare with Julia
Test Passed

julia> static_status(() -> length(string(12345)))
(:ok, "")
```

[`static_status`](@ref) reports how far something gets: `:compile_error`, `:link_error`,
`:runtime_error`, `:mismatch` or `:ok`. [`undefined_symbols`](@ref) lists what the compiled code
needs besides libc.

## Reference

```@index
```

```@autodocs
Modules = [StaticCompilerOverrides]
```
