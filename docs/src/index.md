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
* **`===` of unions and of types**: `===` of two objects that are not the same one (so `Dict` and `Set` lookups)
  compares Strings, numbers, tuples and immutable structs (with Strings, Symbols, or other structs in them) by
  their contents, as in Julia. A struct with a field that is a `Union` of types stored inline
  (`Union{Int,Nothing}`), types, and `svec`s report and exit when run, instead.
* **`objectid` and `hash` of a value whose type is not known when compiling** (an element of a `Vector{Any}`, a field of
  an abstract type that is not a Union): they need the type when the program is run, and are rejected. Structs,
  tuples, Strings and the like are fine as keys of a `Dict` or `Set`, with the same `objectid` as Julia's.
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

## Memory and the garbage collector

Compiled programs have a garbage collector, so memory that the program is not using any more is freed, as in Julia. It is
on by default (on macOS and Linux); `gc = false` in `compile_executable` (and the other entry points) leaves it out, and then
**nothing is ever freed**, which suits a program that runs briefly or allocates a bounded amount in total, and is the
simplest and fastest.

```julia
exe = compile_executable(main, (Vector{String},), "build", "program")                # with the collector
exe = compile_executable(main, (Vector{String},), "build", "program"; gc = false)   # without it
```

The collector and the allocator it works with (`src/heap.jl`) are written in Julia, and compiled with StaticCompiler into every
program that allocates. How it works:

* **Conservative and non-moving.** It doesn't need to know the types of what is in memory. Every word of the stack (and the
  registers), of the data that the program has copied from the compiler (a `const` container that is changed to refer to new
  objects, for instance), and of the objects that it reaches, that is the address of an object, or of anything inside it (or just
  after the end of it, which is what a loop that has gone past the end of an array holds), keeps that object. A number that looks
  like an address may keep an object that is not used, but can't make anything unsafe, and the objects don't move, so the addresses
  that the code holds stay right.
* **It knows what can't refer to anything.** Strings, arrays of numbers, boxed numbers and the like, which the compiler can tell
  from their type, are not looked inside, so a large array of numbers costs nothing to collect.
* **Small objects** are in blocks of 64 kB of one size class (23 of them, up to 2 kB), with a bitmap for the cells in use and
  one for those reached; **large objects** have memory of their own. An allocation is a few instructions. Nothing is zeroed
  twice: memory from the system is zero, and a cell is zeroed when it is reused.
* **When:** a collection is made when as much has been allocated since the last as is alive after it (and at least 8 MB), so
  the heap is at most about twice what the program uses, and a program that allocates less than 8 MB never collects.

In a loop that makes two small objects each time, 10 million times, the collector keeps the program at 9 MB, from 764 MB
without it, and it is faster as well (0.05 s, from 0.22 s), as the memory that is used again is in the cache.

`GC.gc()` collects, and `GC.enable(false)` stops collections until `GC.enable(true)`. In a compiled program, `gc_heap_bytes()`,
`gc_live_bytes()` and `gc_collections()` say how much memory the heap has from the system, how much was in use after the last
collection, and how many collections there have been.

!!! warning "What the collector can't see"
    A reference that is not in the stack, the registers, or an object of the heap, or in the data that the compiler copied, is not
    looked at, and what it refers to is freed if nothing else refers to it. That is the case for memory that the program gets by
    itself: a `MallocArray` or `malloc` that holds the address of an object (they are for plain data, and don't normally), and a
    `Ptr` that is hidden (made from a number that is changed). `pointer(x)` of an array or string is fine for as long as `x` is
    alive, as in Julia (use `GC.@preserve` when `x` is not used after it), and an address of an object that is kept in the stack,
    in a register, or in memory of the heap, is seen.

### Without the collector (`gc = false`)

Everything that Julia would heap-allocate and later collect is never freed. What allocates:

* every array (`zeros(n)`, `collect(...)`, `[x for ...]`, a broadcast `a .+ b`), every `Dict`/`Set`, every `String` built at run
  time (`string(i)`, `"a" * "b"`, `repr`, ...), every escaping closure or mutable struct, every boxed value, and every thrown exception;
* and a container that grows (`push!` onto a `Vector` that is full) leaves its old storage: about twice the final size, and a
  container that is rebuilt in a loop leaves that each time.

What does not: anything the compiler can keep on the stack or remove, for instance a small `Ref` or tuple that does not escape, or
an array that is only used locally and that Julia's optimizer can eliminate. Isbits structs and `StackArray`s are always on the
stack. [`allocation_sites`](@ref) counts the places in the compiled code of a function that allocate (an upper bound, as an
allocation in a branch that is never taken, such as the construction of an exception, is counted too):

```julia
julia> allocation_sites(i -> sum(abs2, 1:i), (Int,))
0

julia> allocation_sites(i -> sum(collect(1:i)), (Int,))
2
```

To avoid the growth in a program without the collector: allocate once, outside the loop, and reuse the memory (`resize!`, `fill!`,
in-place `.=` and `mul!`, `empty!`); prefer `StackArray`s from StaticTools for small, fixed-size data; use `MallocArray`/`MallocString`
and `free`, or `@no_escape`/`@alloc` from Bumper.jl, for memory with a clear lifetime; and write with `printf` or `print` instead
of building strings in loops.

### Testing the collector

The collector is tested on the host against an oracle (random graphs of objects, of which what is reached is known), and by
compiling programs with it. `gc = N` (a number) is a mode for finding mistakes: the collector also runs every `N` allocations,
and what it frees is overwritten, so that a use of memory that was freed is seen at once. All of the tests can be run so with
the environment variable `STATIC_COMPILER_OVERRIDES_GC` (`false`, `true`, or a number), which sets the default of `gc`.

## Exceptions

`try`/`catch`/`finally` and `rethrow` work, as long as the exception was thrown by code in the
same program. They are implemented with `setjmp`/`longjmp` and a fixed-depth handler stack (256
nested `try` blocks).

An exception that no `try` catches prints `fatal: uncaught exception (no handler to catch it)`
and exits with status 1. The message does not say which exception it was.

Limitations, which are bugs rather than design choices:

* `catch e; e isa T` works with concrete types, and with abstract ones for constants (objects have type
  tags, and the types that the code mentions are in the binary; see [Type tags](@ref)). `isa` with an abstract type
  or a `Union` works on boxed values too; the answers come from a table that is made when compiling (see [Type tags](@ref)).
* Code that needs dynamic dispatch, or other things from the Julia runtime, is rejected when
  compiling (see strict mode). With `strict = false`, it compiles and aborts with
  `Dynamic behavior is not supported in standalone binaries (...)` if the call is reached.

## Type tags

Every object that a compiled program allocates has a type tag in its header, as in Julia: a small number for
the built-in types and the address of the type object otherwise. `isa` with a concrete type, the type of a caught
exception, and `show` of an `Any` element read this tag. The objects that the code refers to as constants
(strings, tuples, types, ...) are copied into the binary with their tags, and so are the type objects that
the tags and `isa` with abstract types read (names, parameters). Details are in `src/tags.jl` and `src/runtime.jl`.

`x isa Number` for an `x` that is only known when the program runs is `ijl_subtype(typeof(x), Number)` in libjulia, whose
subtyping algorithm is not in the binary. The types that it is asked about are constants of the code, and the types
that an object can have are those in the binary, so the answers are worked out when compiling, with Julia's own `<:`, and
written out as the function `ijl_subtype`: a table of which types in the binary are subtypes of each type that is asked
about. A type that is computed when the program runs (`isa(x, types[i])`) is not a constant: it is rejected when compiling.

## Binary size

A program has the code it uses, and the Julia objects that it refers to, copied into the binary (strings, constant
arrays and `Dict`s, and the type objects that the type tags and `isa` read). Measured on macOS (arm64, Julia 1.14.0-alpha2) from the
`__text` and data sections of the executables (the file sizes are in 16 kB pages):

| program                                  | code (`__text`) | data    |
|:-----------------------------------------|----------------:|--------:|
| `0`                                      |    56 B         |   5 B   |
| `println("hello")`                       |   120 B         |  62 B   |
| `println(42)`                            |   1.4 kB        | 17.2 kB |
| `println([1, 2, 3])`                     |   2.3 kB        | 17.9 kB |
| `println(Dict(1 => 2))`                  |   3.8 kB        | 20.7 kB |
| `Dict` with struct keys, lookup          |   4.3 kB        | 15.0 kB |
| `x isa Number` on boxed values           |   0.8 kB        | 30.9 kB |
| `println(Any[1, "a", 2.5])`              |  36 kB          | 65 kB   |
| `repr([1.5, 2.5])`                       |  14 kB          | 37 kB   |

What is in the data of a program that prints a number is mostly two things: about 12 kB of objects, the type of `Int64`
that the error for a conversion that fails (an `InexactError`) holds, with the types that it refers to (its supertypes, the names of
the types and of their fields), and 5 kB that is zero at the start (the stack of the exception handlers and the task that
the runtime stands in for). A program without any code that can throw (`println("hello")`) has neither.
What the program does not use is not there: the plans for `===` of the types, which are about 14% of the objects of a
program that compares objects, are made only if the code calls `jl_egal__unboxed`; and the table of the types of the small
tags is made only if the code indexes it with something that is not a constant (`isa` on a boxed value does), and
otherwise each of the types that the code names is the one object. The `isa` table (`ijl_subtype`) is as large as the
number of types asked about times the number of types in the binary that are subtypes of them.
The collector itself is about 12 kB of code and 6 to 10 kB of data in a program that allocates (so the sizes above, which are of programs
without it, are that much smaller than a default build; `gc = false` leaves it out).
`println(Any[...])` is larger because it has the code to show each of the types in `show_candidates`: add only the types
that you need with [`add_show_candidates!`](@ref) (the defaults can't be removed yet).

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
