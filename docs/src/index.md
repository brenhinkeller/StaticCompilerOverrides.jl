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
`rand`/`randn` on the default RNG, linear algebra (see [Linear algebra and BLAS](@ref)), and `try`/`catch`/`finally`/`rethrow` (including for errors thrown by Base, like `BoundsError`), in addition to what
StaticCompiler already handled (allocation-free numerical code, StaticTools types, and so on).
The tests in `test/corpus.jl` are the up-to-date list of the idioms that we check, and which of
them are known not to work yet. [Known limitations](@ref) gathers what does not work, or works differently.

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
* `show` of matrices, and of containers that are not arrays, tuples, pairs,
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

## Dynamic dispatch on abstract types and on `Any`

A call whose argument has an abstract type, such as `area(x)` for an `x` from a `Vector{Shape}`, runs the method that fits the
type that `x` has when the program is run. In Julia that is a lookup in the method tables, which a standalone binary does not
have. Here it is resolved when compiling, by what Julia does for a `Union`: test which of the types the argument has, and call
the method for that type.

```julia
abstract type Shape end
struct Circle <: Shape; r::Float64; end
struct Rect <: Shape; w::Float64; h::Float64; end
area(c::Circle) = pi * c.r^2
area(r::Rect) = r.w * r.h

shapes() = Shape[Circle(1.0), Rect(2.0, 3.0)]
main(argc::Int, argv::Ptr{Ptr{UInt8}}) = (println(sum(area, shapes())); 0)
compile_executable(main, (Int, Ptr{Ptr{UInt8}}), "build")      # works
```

Which types the union has depends on the type of the argument:

* **An abstract type that has up to 16 concrete subtypes, which can all be listed**: the union is of all of them, defined when
  compiling, and that is all of the types that an object of the program can have. Nothing is left to chance: an object of a type
  that was not there is a `MethodError`, as in Julia. A package that defines more subtypes of `Shape` adds them to the union, and
  their methods to the code. (`StaticCompilerOverrides.DISPATCH_LIMIT[]` is the limit of 16.)
* **`Any`, and abstract types that can't be listed** (`Number`, `AbstractString`, `AbstractArray`, or one that has a parametric
  subtype whose instances are not known): the union is of the types that are *registered*, that are subtypes of it. These are
  the numbers, `String`, `Char`, `Symbol`, `Nothing` and `Missing`, the same types that `show` of a value of `Any` uses (so
  `println(x)` of an element of a `Vector{Any}` works), and what you add:

  ```julia
  add_dispatch_candidates!(MyType, Tuple{Int,Float64})   # before compiling; the same list as `add_show_candidates!`
  ```

  A value of a type that is not registered **aborts the program when it reaches such a call**, with a message that says which
  call (`MethodError: no method matches the types of the arguments of a call of `f``), because it is not known when compiling
  which types the values of an `Any` can have. So compiling says, once for what it did this way, what was resolved over the
  registered types, in a debug message (set `JULIA_DEBUG=StaticCompilerOverrides` to see it). Calls on values whose types are all registered
  are as fast as any other call: it is a few comparisons of the type tag. A binary that does not have such a call is not
  bigger for the list.

  `Vector{Any}` is not among the usual types for dispatch (though it is for `show`), because it has methods of arithmetic and the like
  that a call on a number would need: register it if the values that you call things on include lists.

It applies to a call that is a dispatch on the types of its arguments (more than one method fits, or the one that does doesn't fit
all that the arguments can be). A call of one method that fits all of them is not changed. A call with several arguments of
these types has a case for each combination, up to 64 of them (`StaticCompilerOverrides.SPLIT_LIMIT[]`): `x + y` of two values of
`Any` is split, and `sort` of a `Vector{Any}` too.

Still dynamic, and rejected when compiling:

* Types that can't be listed, with no registered subtype (`IO`: use `STDOUT`, `STDERR`, `STDIN`, or a type that you know).
* Types and methods that are made after compiling (there is no `eval`).
* Calls that compute a type from the types of the arguments at run time (`Dict(k => v)` of pairs with abstract values, `typejoin`,
  `sum(f, v)` of a `Vector{Any}`, whose element type is a union of the results).

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

!!! warning "One thread"
    The heap is not thread-safe: a compiled program, or a library made with `compile_shlib`, must allocate from one thread at a
    time (a library that is called from several needs a lock around its calls: `gc = false` does not help, that allocator is not
    thread-safe either). The collector looks at the stack of the thread that calls it, from the base of that stack (on Linux, that
    of the main thread). If the library is called on a stack that is not that, for instance from a task of Julia running on another
    thread, it does not know where the references are, so it **frees nothing** in that call (the memory grows until the program
    is called from a thread that it can collect from).

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
| `println(42)`                            |   1.4 kB        |  9.7 kB |
| `println([1, 2, 3])`                     |   2.3 kB        | 10.2 kB |
| `println(Dict(1 => 2))`                  |   3.8 kB        | 11.0 kB |
| `Dict` with struct keys, lookup          |   4.3 kB        |  6.6 kB |
| `x isa Number` on boxed values           |   0.8 kB        |  2.7 kB |
| `println(Any[1, "a", 2.5])`              |  36 kB          | 41.5 kB |
| `repr([1.5, 2.5])`                       |  14 kB          | 22.4 kB |

What is in the data of a program that prints a number is mostly two things: about 4.5 kB of objects, the type of `Int64`
that the error for a conversion that fails (an `InexactError`) holds, with the name of it; and 5 kB that is zero at the start (the stack of
the exception handlers and the task that the runtime stands in for, which are not in the file). A program without any code that can throw
(`println("hello")`) has neither. The objects that are types are copied for what a program does with them: telling the type of an
object from another (the tag), its name (`nameof`) and its parameters. Not for what a type refers to: its supertypes, the wrapper
and the names of the fields. A program does not have these (a call that would need them is dynamic anyway), and with them
the objects of a small program were more than twice as many. Showing a string needs a table of the characters that can be printed,
which is about 6 kB (and not that of the categories of all characters, which is 21 kB).
`%f` of a `Float64` in `@printf` needs the tables of Ryu for the fixed format, which are 190 kB: `%g`, `%e` and `show` have much smaller ones.
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

## Linear algebra and BLAS

Matrix products, `dot`, `norm`, `\`, `inv`, `det`, `lu`, `qr`, `cholesky`, `eigvals`, `svdvals` and so on work, for the
element types that BLAS and LAPACK have. `LinearAlgebra` does these by calls of [libblastrampoline](https://github.com/JuliaLinearAlgebra/libblastrampoline)
(LBT), which passes each on to the library that backs it: OpenBLAS by default, and another when a package such as
[AppleAccelerate.jl](https://github.com/JuliaLinearAlgebra/AppleAccelerate.jl) or [MKL.jl](https://github.com/JuliaLinearAlgebra/MKL.jl) forwards to it
(`BLAS.lbt_forward`). A program does the same: **it uses the libraries that were in use when it was compiled.**

```julia
using StaticCompilerOverrides, LinearAlgebra
using AppleAccelerate; AppleAccelerate.load_accelerate()    # (or `using MKL`: any library that LBT forwards to)
compile_executable(main, (Int, Ptr{Ptr{UInt8}}), "build")   # the program calls Accelerate
```

How it works: LBT, and the libraries that it forwards to (those of `BLAS.get_config()` that something is forwarded to, in the
order that they were loaded, with their suffixes), are not in the binary. Their paths are, and the first time that
the program calls a function of BLAS or LAPACK it loads LBT (`dlopen`), forwards to those libraries as `lbt_forward` does, and looks the function up
(`dlsym`), as Julia does for a `ccall` that is made the first time. A program that does not call BLAS loads nothing. So:

* The libraries must be at the same paths when the program is run as when it was compiled (for the ones that come with
  Julia, that is the `lib` directory of the Julia that was used, and the artifacts of its packages). A program that is run
  elsewhere says `Cannot load libblastrampoline (for BLAS)` and exits.
* The program can use more than one thread, if the library does.
* Large calls of BLAS can't be cancelled (there are no tasks to cancel).
* This is tested with OpenBLAS and Accelerate. MKL is not available for the machines that we test on (macOS on ARM), but it is
  a library that LBT forwards to like the others.

The element types and sizes are the ones that BLAS and LAPACK take (`Float64`, `Float32`, `ComplexF64`, `ComplexF32`): other
types use generic Julia code, which compiles like any other. Functions of other packages that call into their own
libraries (SuiteSparse, Arpack, ...) need those libraries, and don't work yet.

## Random numbers

`Random.default_rng()` (a `TaskLocalRNG`) keeps its state in the current task, which does not
exist in compiled programs. It is replaced by a global xoshiro256++ state, seeded from the
operating system (`getentropy`) when first used, like Julia seeds a new process. `Random.seed!(rng,
seed)` works for explicitly constructed generators. The default generator is not thread-safe, as
there are no threads. `Random.seed!(seed)` on the default generator does not work yet.

## Known limitations

What does not work yet, or works differently from Julia, gathered in one place. The sections above say more about each.

**Platforms**

* **macOS and Linux** only for the collector (`gc = true`); elsewhere it is off by default, and `gc = true` is an error. **Linux is
  not tested yet** (only macOS on ARM): the collector depends on the layout of the stack and `setjmp` of the C library, and BLAS on `dlopen`.
* **The host is the target.** The heap and the runtime are made for the machine that compiles, so cross-compiling (a `target` that is
  not the host) is not supported.
* BLAS and LAPACK need LBT and the libraries that back it **at the same paths when the program is run** (see
  [Linear algebra and BLAS](@ref)); they are not in the binary.

**Threads, tasks and `eval`**

* There are **no tasks, `Channel`s, `@async` or `Threads.@spawn`**, no `eval` or `invokelatest`, and no `Regex`, `BigInt` or `BigFloat` (they
  need libraries that are not there: PCRE, GMP and MPFR).
* **The heap is not thread-safe.** A program, or a library from `compile_shlib`, allocates from one thread at a time. A library that
  is called on a stack that is not that of the thread (a task of Julia running on another thread) **frees nothing** in that call
  (see [Memory and the garbage collector](@ref)).

**What is dynamic**

* **Dynamic dispatch** is resolved for abstract types with at most 16 concrete subtypes that can be listed, and for `Any` and the other
  abstract types over the registered types (see [Dynamic dispatch on abstract types and on `Any`](@ref)): a value of a type that is not
  registered aborts the program when it reaches such a call. It is not resolved for types that can't be listed and have no registered
  subtype (`IO`). These, `Core.Box` variables with a type that is not known, **non-`const` globals**, splatting a collection whose
  length is not known when compiling (`f(v...)`), and calls that compute a type at run time (`typejoin`, a `Dict` made from pairs
  with abstract values, `sum(f, v)` of a `Vector{Any}`, `isprime`) are rejected when compiling (`UnsupportedCodeError`), or abort the
  program if compiled with `strict = false`.
* **Values that are only known at run time** (an element of a `Vector{Any}`) can't be the argument of `objectid` or `hash` unless their types
  are registered, nor `===` of types and unions, and `show` of one is limited to the registered types (see [`show` of containers, types and structs](@ref)).
* **Symbols from strings** (`Symbol("a", "b")`) and `deepcopy` (an `IdDict`), `titlecase` (it needs the grapheme breaks of utf8proc),
  the `MersenneTwister` generator, and `Random.seed!(seed)` of the default generator need things of libjulia that are not there.

**What a binary starts with**

* **What the compiling Julia has is copied.** A `const` container, a `Ref`, a string, ... is in the binary as it was when compiling, and
  the program changes its own copy (so `ARGS` is set by the program, from its command line; and a global that the program changes
  does not change the Julia that compiled it). Only what is of a type that can be reproduced is copied: not a `Module`, a function
  with captured state, a `Task`, ...
* **The collector is conservative:** it finds references by what looks like an address, so a number can keep an object that is not
  used, and a reference that is hidden (not in the stack, the registers, the data copied from the compiler, or an object of the heap)
  is not found. Memory that is allocated with `malloc` is not looked at (see [Memory and the garbage collector](@ref)). **The blocks of small objects
  are not returned to the system** once the heap has them (though they are used again); large objects are.

**Differences from Julia when the program runs**

* **At most 256 `try` blocks are active at once** (and 256 exceptions being handled): more prints `fatal: exception handler stack overflow`
  and exits. An exception that nothing catches prints `fatal: uncaught exception (no handler to catch it)` and exits with status 1,
  without a backtrace or the message of the exception.
* **There is no stack overflow check:** infinite recursion crashes (segmentation fault) instead of throwing `StackOverflowError`.
* **Locks do nothing** (there is one thread), `islocked` is `false`, and `yield` returns at once.
* **Files** are libc streams: `eachline` of a file closes it only when the loop reaches the end (not on `break`), `seek` and
  `skip` don't report errors, `open` takes only a C `fopen` mode, and the keyword arguments of `readline` and `eachline` (`keep = true`)
  are not supported. The file system (`isfile`, `mkdir`, `readdir`, ...) and sockets are not available.
* **`rand` without a seed** gets its state from the operating system (`getentropy`); if that fails, from fixed words, so then it is
  always the same stream.
* The output is **unbuffered beyond libc's**: `print` and `println` write through `FILE*`, which libc flushes when the program exits
  (not if it crashes).

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
Modules = [StaticCompilerOverrides, StaticCompilerOverrides.Runtime]
```
