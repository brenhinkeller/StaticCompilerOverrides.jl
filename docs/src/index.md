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

### The file system

`stat` (and `isfile`, `isdir`, `ispath`, `filesize`, `mtime`, `filemode`), `mkdir`, `rm` (with `force` and `recursive`), `readdir` (with `join` and `sort`), `mv`, `cp` (of a file or a directory), `pwd`, `cd`,
`realpath`, `homedir`, `tempdir`, `tempname`, `mktemp`, `mktempdir` (and with a function), `ENV[name] = value` and `delete!(ENV, name)`, and `Libc.getpid` are done with the functions of the C library. What is different: an
error is a `SystemError` with the message of `strerror`, where Base's is an `IOError` that has the code of libuv (a program that catches `IOError` for a missing file catches `SystemError` here), and `symlink`,
`chmod`, `touch`, `mmap` and starting other programs (`run`, ``read(`cmd`, String)``) are not supported. `Threads.@threads` runs the loop on the one thread, in order.

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
dynamic. Here the same output is made with what is known when compiling (`src/show.jl`, `src/context.jl`), and most of what Base does is Base's own code:

* the name of a type is a constant string made by Base's own `show` when compiling, so it is what Base prints;
* the **properties of the context** (`:typeinfo`, `:compact`, `:limit`, `:displaysize`, ...) are in the type of the stream (`ContextIO`), so that asking for one is a
  constant (see the next section);
* what Base's `typeinfo_prefix` does with the type of the elements is done when compiling, for the type of the container;
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

Arrays of any number of dimensions are shown by Base's code (`println(A)`, `repr(A)`, `"$A"`): the overlays only take away what makes Base compile the code once for all
arrays, a matrix made a value of the type `Any` for the compiler (`inferencebarrier`), which would be a dynamic call. `Dict`s, `Set`s and vectors are Base's too; tuples, pairs and structs are written by
methods of this package (Base's reads the dictionary of an `IOContext` directly).

### `IOContext`, `text/plain` and `display`

`IOContext(io, :compact => true, :limit => true, ...)` of the streams of the program (`STDOUT`, `STDERR`, files, and what `sprint` writes to) has the properties in its *type*, so asking
for them (`get(io, :compact, false)`) is a constant when compiling, and what depends on it is decided then. So their **values have to be known when compiling** (a `Bool`, a number, a type, a tuple of
those): `IOContext(io, :compact => flag)` with a `flag` that is only known when the program runs cannot be resolved (compiling says so). `:SHOWN_SET` (the containers that contain
themselves, which are not detected) and `:module` are not kept. The properties then do what they do in Julia:

```julia
show(IOContext(STDOUT, :compact => true), 0.1 + 0.2)          # 0.3
show(IOContext(STDOUT, :limit => true), collect(1:30))        # [1, 2, 3, 4, 5, 6, 7, 8, 9, 10  …  21, 22, 23, 24, 25, 26, 27, 28, 29, 30]
```

`show(io, MIME"text/plain"(), x)` and `display(x)` (which writes the `text/plain` form to the standard output, as the `TextDisplay` of a Julia script does) write matrices aligned, with the
size and type above them, and vectors, ranges, dictionaries, sets and structured matrices (`Diagonal`, `Symmetric`, ...) as Julia does. Base lines up the numbers of a column by finding the
decimal point (or the sign of the imaginary part, or the `//`) with regular expressions, which a program does not have: the same is found by a scan of the text. With `:limit` and
`:displaysize` the output is cut as Julia cuts it (`display` does not set them, as on a terminal that is not one).

Limits: containers that contain themselves are not detected (they recurse until the program crashes); the keyword `context` of `sprint` with a pair that is written in the call
(`sprint(show, v; context = :compact => true)`) works for what is not an array, and is not yet supported for the show of an array (give `IOContext` the stream instead, or a context that is
a stream); `text/plain` of a `UniformScaling` (`2I`) is not supported (it uses a regular expression); a
`Symbol` that the program makes and that is not a plain ASCII identifier is written as Base writes it only if that is clear without the parser's tables
(`Symbol("a b")`, `Symbol("1a")`, `Symbol("")`), and else it is an error (the symbols that were there when compiling, such as `:+` or `:α`, are written as Julia writes them: see
[Symbols](@ref)); and the names of types of modules that are loaded after this package (`using` in the program) are written with their module (Base writes
`Main`'s view of them).

## Symbols

Julia keeps every symbol in one table, so that there is one object for each name and `===` of symbols compares addresses. A program has no such table, so:

* The symbols that the program has when it is compiled are copied into it, as any constant is, so `Dict`s and `Set`s of symbols that are `const` work (a symbol
  hashes by a number that is in it, which the copy has too), and so does `string(sym)`, `print`, `sort`, `startswith(string(sym), ...)`, and the like.
* `Symbol("abc")`, `Symbol("x", 1)`, `Symbol(uppercase(string(s)))` and `Symbol(::Vector{UInt8})` of a name that the program makes work too. The binary has a list of
  its symbols, sorted by name, that is looked in first, so `Symbol("abc") === :abc` and a `Dict` that was made when compiling finds a key that the program made; a name
  that is not in it is made into a new symbol, kept in a tree (the same as the table of Julia is: by hash and name). These symbols are never freed (40 bytes and the name
  for each different name), and their names can't have a NUL in them.
* `show` of a symbol writes `:name` for a name that is a plain ASCII identifier. For other symbols, Julia decides with tables of its parser (`:+`, `:(==)`, `:α`, `Symbol("a b")`):
  for those that the binary has, it writes what Julia writes (the text is made when linking); for those that the program makes, only the names that are certainly not
  identifiers or operators (empty, with a space or a control character or a quote, or starting with a digit) are written, as `Symbol("...")`; any other is an error.
* Types as keys: `==` of types, `hash` of a `DataType`, and so `Dict{DataType,...}` and `Set{DataType}`, work (a type hashes by the number that it has in it). `==` of types
  that are not both concrete (a `Union`, an abstract type with parameters) goes by `<:` (see [Dynamic dispatch on abstract types and on `Any`](@ref)).
* Not supported: `getfield(x, name)` and `x[name]` of a `NamedTuple` with a `Symbol` that is only known when the program runs (it needs the types of the fields).

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

*How this is done without changing other compilations.* The changes to inference (resolving the dispatch, `invokelatest`) are methods of functions of Julia's compiler
for an interpreter of a type that only our compilations have: the type of GPUCompiler's `GPUInterpreter` has the view of the method tables that it looks methods up in as a
parameter, and our compilations choose a view of a type of their own (`OverridesTableView`, through `GPUCompiler.method_table_view`). What StaticCompiler compiles on its own, in the
same session, has GPUCompiler's own interpreter and is not changed.

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

### Functions that are not known: closures in collections and in boxes

A call `f(x)` of an `f` whose type is not known when compiling (a `Function` from a `Vector{Function}`, a `Dict` of functions, a field of the
type `Function`, a `Ref{Function}`, a value of `Any`, and a closure that calls itself, whose variable is boxed) is a call of the method that fits the
function that `f` is when the program runs. It is made over the types of the functions that the code has, which the compiler tests for one after the other, as it
does for the registered types above. Those are the closures that the code of the program makes, the functions that it passes or stores (`sin` in
`Function[sin, cos]`, `Base.Fix2(+, 1)`), and the ones in the constants that it refers to (`const FS = Function[sin, x -> 2x]`): not those of Base and the standard
libraries, which pass the functions of the program around and are the ones that call them.

```julia
fs = Function[sin, cos, x -> 2x]
function main()
    s = 0.0
    for f in fs        # f is a Function: a case for each function of the program that has a method for a Float64
        s += f(1.0)
    end
    printf(c"%.3f\n", s)
    return 0
end
```

Where the functions are is not known before the code has been inferred, so a compilation that has such a call and fails (or, with `strict = false`, would abort at the call) is made
again with the functions that it found, until it finds no more: it takes longer, but only for a program that has such a call. A function that the program only gets from
somewhere that it can't see (a function that a library calls back, a function made by code that is not part of the program) is not one of the cases, and the call
is rejected when compiling, as before. So is a call that none of the functions has a method for.

### Callbacks: `@cfunction`

`@cfunction` makes a C function pointer of a function of the program, which C code calls (the comparison function of `qsort` and `bsearch`, the callback of a library):

```julia
cmp(a::Ptr{Cint}, b::Ptr{Cint})::Cint = (x = unsafe_load(a); y = unsafe_load(b); x < y ? -1 : x > y ? 1 : 0)

function main()
    v = Cint[3, 1, 2]
    f = @cfunction(cmp, Cint, (Ptr{Cint}, Ptr{Cint}))
    ccall(:qsort, Cvoid, (Ptr{Cint}, Csize_t, Csize_t, Ptr{Cvoid}), v, 3, 4, f)
    println(v)
    return 0
end
```

The function is compiled with the types of C, and can allocate and call anything else that the program can (an exception that is thrown in it must be caught in it: it can not unwind the C frames). What Julia generates for it looks the method up
when it is first called (`jl_get_abi_converter`), which a program can't do; so the code is compiled again with a function for each `@cfunction` that calls the method,
where the entry point can't reach it, and the C function is made to call that: as with the functions of closures, that takes a second pass, for a program that has a `@cfunction`.
What it does not do: a function that has captured state (a closure over a variable, `@cfunction($f, ...)` of a `f` that is not a function without fields), a function that is not
known when compiling, arguments that are not C types (`Ref`, `Any`), and the callback of a library that is called from a thread that Julia did not make. (Callbacks run on the
stack of the caller, which the collector scans, so what they allocate is collected.)

## Memory and the garbage collector

Compiled programs have a garbage collector, so memory that the program is not using any more is freed, as in Julia. It is
on by default (on macOS and Linux); `gc = false` in `compile_executable` (and the other entry points) leaves it out, and then
**nothing is ever freed**, which suits a program that runs briefly or allocates a bounded amount in total, and is the
simplest and fastest.

```julia
exe = compile_executable(main, (Vector{String},), "build", "program")                # with the collector
exe = compile_executable(main, (Vector{String},), "build", "program"; gc = false)   # without it
```

The collector and the allocator it works with (`src/runtime/heap.jl`) are written in Julia, and compiled with StaticCompiler into every
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
the tags and `isa` with abstract types read (names, parameters). Details are in `src/tags.jl` and `src/runtime/embedder.jl`.

`x isa Number` for an `x` that is only known when the program runs is `ijl_subtype(typeof(x), Number)` in libjulia, whose
subtyping algorithm is not in the binary. The types that it is asked about are constants of the code, and the types
that an object can have are those in the binary, so the answers are worked out when compiling, with Julia's own `<:`, and
written out as the function `ijl_subtype`: a table of which types in the binary are subtypes of each type that is asked
about. When the type is not a constant of the code (`isa(x, types[i])`, `a <: b` of two elements of a `Vector{DataType}`, `eltype(c) <: C`), the table
has an answer for each pair of the types that are in the binary (a bit each, found by searching for the two types), and `jl_f_issubtype` and `jl_f_isa`, the
builtins that these calls are, look in it. So `<:` and `isa` work for any types that are in the binary: the types of its objects, the types that it names, and the
types that those refer to. A type that the program makes up (`Vector{T}` for a `T` that is computed, anything with a `TypeVar`) is not in the binary, and the program exits with a
message if it is asked about; `a <: b` of types that a function builds this way is rejected when compiling. The table has a row and a column for each type in the binary, so it
grows with the square of their number (about 125 kB for a thousand types), and is only there if the code asks about types that are not constants.

## Binary size

A program has the code it uses, and the Julia objects that it refers to, copied into the binary (strings, constant
arrays and `Dict`s, and the type objects that the type tags and `isa` read). What is not used is not there. Measured on macOS (arm64,
Julia 1.14.0-alpha2): the bytes of the sections of the executable that are in the file (code, constants and data; `size -m`), and the file, which is made of pages of 16 kB
and has the table of the symbols of the entry point. The last two columns are with `small = true` (see below):

| program                                            | sections | file    | sections, `small` | file, `small` |
|:---------------------------------------------------|---------:|--------:|------------------:|--------------:|
| `main(argc, argv)`: `println("hello")`             |   2.1 kB |  51 kB  |    2.1 kB         |  34 kB        |
| `main(argc, argv)`: `println(fib(30))`             |   8.9 kB |  54 kB  |    8.9 kB         |  34 kB        |
| `main(args)`: `println("hello")`                   |  28 kB   |  73 kB  |   13 kB           |  34 kB        |
| `main(args)`: `println(length(args) + 42)`         |  32 kB   |  75 kB  |   17 kB           |  35 kB        |
| a `Dict` of strings, a lookup                      |  38 kB   |  77 kB  |   38 kB           |  52 kB        |
| `parse(Int, ...)` in a `try`, the message printed  |  73 kB   | 115 kB  |   60 kB           |  69 kB        |
| `sqrt` and `println` of a `Float64`                |  76 kB   | 111 kB  |   61 kB           |  84 kB        |
| `sort(rand(100))`                                  |  77 kB   | 131 kB  |   77 kB           | 101 kB        |
| a sieve of Eratosthenes (the README example)       | 122 kB   | 152 kB  |  110 kB           | 135 kB        |
| a `Dict` of tuples, a matrix product, `display`    | 196 kB   | 244 kB  |  196 kB           | 217 kB        |

What a program has, and when:

* **The collector** (20 kB of code and 8 kB of data) is there if the program allocates anywhere that it can go on from. A program that allocates only where it is about to stop (the message
  and the exception of an error that nothing catches, or that a `try` only runs the `finally` of) never frees anything, and has the allocator that doesn't collect: that is what `main(argc, argv)` with `println` is. A
  `main(args)` makes the vector of the arguments, which is an allocation that goes on. `gc = false` leaves the collector out of any program.
* **The support for finalizers** (5 kB) is there if the program registers a finalizer (`BigInt`, the wrappers of libraries, `finalizer(f, x)`).
* **The tables of the characters** are one for each question that is asked: `isspace` of a character that is not ASCII is a table of a few bytes; `show` of a string (the printable characters) 12 kB; `isletter`
  and the like 33 kB.
* **The collector looks at** only the objects that can refer to objects of the heap: not strings, symbols, arrays of numbers, or types.

**`small = true`** (for `compile_executable`; `compile_shlib` takes the flags only) makes a smaller file where that makes no difference to what the program does:

* The program has **no collector if it allocates a finite amount of memory in all**: nothing that it allocates is in a loop, or in a function that is called from a loop or that calls itself (or that something refers to without
  calling it: a callback of a library). The memory that it has is then what it allocates, and not what it would allocate for as long as it runs. A `try` that catches, and goes on, counts if it is not in a loop either. A `sort`, a `Dict` that grows,
  or a `split` have loops that allocate, and keep the collector; so does anything that allocates in a loop, or in a function that is called from one.
  (The arguments of the command line are made by a loop, which is as long as they are: that is not counted.) The analysis is of the code, and not of the sizes: a program that allocates a gigabyte once has no collector, and
  the gigabyte.
* The linker leaves out the **names of the functions** of the program, but its entry point (on macOS, `-x`: 5 to 25 kB; on Linux `-s`, not tried yet), and, on macOS, the segment for the **constants and the table of the addresses
  of functions** that is made read-only when the program starts (`-no_data_const`: a page of 16 kB, of which a small program uses a few hundred bytes; it is also a protection that the program then does not have).
  Passing your own `cflags` replaces these.

What is in the data of a program that prints a number is mostly two things: about 4.5 kB of objects, the type of `Int64`
that the error for a conversion that fails (an `InexactError`) holds, with the name of it; and 5 kB that is zero at the start (the stack of
the exception handlers and the task that the runtime stands in for, which are not in the file). A program without any code that can throw
(`main(argc, argv)` with `println("hello")`) has neither. The objects that are types are copied for what a program does with them: telling the type of an
object from another (the tag), its name (`nameof`) and its parameters. Not for what a type refers to: its supertypes, the wrapper
and the names of the fields. A program does not have these (a call that would need them is dynamic anyway), and with them
the objects of a small program were more than twice as many. Showing a string needs a table of the characters that can be printed,
which is about 12 kB (and not that of the categories of all characters, which is 33 kB).
`%f` of a `Float64` in `@printf` needs the tables of Ryu for the fixed format, which are 190 kB: `%g`, `%e` and `show` have much smaller ones.
What the program does not use is not there: the plans for `===` of the types, which are about 14% of the objects of a
program that compares objects, are made only if the code calls `jl_egal__unboxed`; and the table of the types of the small
tags is made only if the code indexes it with something that is not a constant (`isa` on a boxed value does), and
otherwise each of the types that the code names is the one object. The `isa` table (`ijl_subtype`) is as large as the
number of types asked about times the number of types in the binary that are subtypes of them.
`println(Any[...])` is larger because it has the code to show each of the types in `show_candidates`: add only the types
that you need with [`add_show_candidates!`](@ref) (the defaults can't be removed yet).

## Compared with C and C++

The same programs in C and C++ (Apple clang 14, `-O2`) and in Julia compiled by this package (macOS, Apple M1 Max; the time of the best of 3 runs, in seconds; the answers are the same). The Julia of the loops has `@inbounds` as the C has no checks, and the
data are laid out as in C.

| program                          | C       | C++     | here    | here, `small` (file) |
|:---------------------------------|--------:|--------:|--------:|---------------------:|
| recursive `fib(38)`              | 0.12    |         | 0.15    | 34 kB (C: 33 kB)     |
| sieve of Eratosthenes (50M)      | 0.10    |         | 0.11    | 34 kB                |
| matrix product (500, loops)      | 0.022   |         | 0.022   | 34 kB                |
| Mandelbrot (1500)                | 0.25    |         | 0.26    | 34 kB                |
| n-body (5M steps, array of structs) | 0.28 |         | 0.25    | 69 kB                |
| Collatz (3M)                     | 0.43    |         | 0.43    | 69 kB                |
| `sin`, `exp`, `log`, `atan`, `sqrt` (20M) | 0.25 |      | 0.39    | 102 kB               |
| binary trees (allocation, depth 18) | 1.7  |         | 1.2     | 85 kB                |
| string building and parsing (2M) | 0.13    | 0.067   | 0.10    | 102 kB               |
| sort of 3M integers              | 0.27 (`qsort`) | 0.18 (`std::sort`) | 0.023 | 102 kB |
| hash table of 2M keys            |         | 0.45    | 0.14    | 85 kB                |

(The file sizes of the first four are for programs with `main(argc, argv)` and `atol` as in C; the others have `main(args)` and `parse`.)

For arithmetic that is made of loops the programs are about as fast as C. What is faster than C or C++ is the library (`sort!` of integers is a counting sort for a small range, and `Dict` is a flat table where `unordered_map` has a node for each key; the allocator
and collector of the binary tree program). The things that are slower: recursion (`fib`; plain Julia is the same: it is LLVM's code for it), and the functions of the math library (Julia's own `sin`, `log`, ... are 1.3 to 2 times slower than those of the C library on this machine).
A program that allocates and keeps memory in lists and hash tables has more of it than C does (the hash table program is 135 MB where C++'s is 75 MB). The files are as small as C's for a program that does not allocate (`small = true`, a raw `main(argc, argv)`), and
tens of kilobytes more when it prints, parses, or allocates in loops (see [Binary size](@ref)).

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

## Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own

A `ccall` into a library is a function that the program looks up when it first needs it. Where that library is, is a choice that the compiler takes as
`libraries`:

```julia
compile_executable(f, types, dir, name)                       # libraries = :system, the default
compile_executable(f, types, dir, name; libraries = :bundle)
```

* `:system` — the program opens the library at the **path that it had when compiling** (the file of the JLL in `~/.julia/artifacts`, or your own
  `libfoo.so`). The program is not independent of that file. If the library has gone, the program says `Cannot use a library that the program calls
  functions of: cannot open <path>` on the standard error and exits (the same if a function is not in it).
* `:bundle` — the libraries (and those that they need: `libmpfr` needs `libgmp`) are copied to the folder `lib` next to the program, and the program looks
  there first, relative to where *it* is, so the folder of the program can be moved or copied to another machine of the same kind. If a library is not there, the path that
  it had when compiling is tried. Libraries of the system (`/usr/lib`, `/lib`, ...) are not copied. For `compile_shlib`, `lib` is next to the shared library.

```julia
function main(args::Vector{String})
    println("30! = ", factorial(big(30)))                      # BigInt (GMP)
    println("sqrt(2) = ", sqrt(big(2)))                        # BigFloat (MPFR)
    m = match(r"(?<key>[a-z]+)=(?<val>\d+)", get(args, 1, "answer=42"))   # Regex (PCRE2)
    m === nothing && return 1
    println(m[:key], " is ", parse(Int, m[:val]) + 1)
    return 0
end

compile_executable(main, (Vector{String},), "build", "bignums"; libraries = :bundle)   # build/lib has libgmp, libmpfr, libpcre2
```

What works through this, and is tested: **`BigInt`** and **`BigFloat`** (GMP and MPFR; the memory that GMP allocates is freed by the collector when the number is,
by the finalizer that Base gives it), **`Regex`** (PCRE2: `match`, `occursin`, `replace`, `split`, `eachmatch`, named captures, `Regex(string)` made when the program
runs), zlib and any other function that a JLL or library has (`ccall((:name, "libname"), ...)`, a `LazyLibrary` such as `Zlib_jll.libz`, or the path of a file).
The functions of the math library (`libm`, `libopenlibm`) are linked by name instead. The libraries of the runtime of Julia (libjulia, libuv, ...) are not there.

Limits: a `Ptr` field of a constant of the program
(an address of this process) is null there, with a warning (a `Regex` is compiled when the program first uses it, so those are fine); `setprecision(f, BigFloat, n)`
(a scoped value) does not work yet. **Linux is only tested on CI for the libraries** (the program finds its own folder with `dladdr`, and `/proc/self/exe`).

## Dates and SparseArrays

Both standard libraries compile, and are checked against Julia in `test/packages/dates.jl` and `test/packages/sparsearrays.jl`.

* **Dates**: `Date`, `DateTime` and `Time` (construction, fields, arithmetic with periods, ranges, `dayofweek` and the like, `monthname`, `show`), parsing a string
  (`Date("2021-12-25")`, `DateTime(...)`, `tryparse`, and with a format), `now()` and `today()` (the time zone of the machine that runs the program). A format is
  made when compiling with the macro: `Dates.format(d, dateformat"dd/mm/yyyy")`. `Dates.format(d, "dd/mm/yyyy")` makes it when the program runs, from the characters of
  the string, which does not compile. (The tokens of a format are of types that differ by a letter, so a package extension of this package registers them for dispatch when
  `Dates` is loaded.)
* **SparseArrays**: `sparse`, `spzeros`, `SparseMatrixCSC`, sparse vectors, indexing and `setindex!`, `nnz`, `nonzeros`, `findnz`, sums, products of sparse with dense and with
  sparse, `transpose`, `kron`, `spdiagm`, `I`, and `show`, and the **factorizations**: `\` of a sparse matrix, `lu`, `cholesky`, `ldlt`, `qr` (and so least squares), `det`, `logdet`, `factorize`, with
  their errors (`PosDefException`, `SingularException`). These are SuiteSparse's libraries (UMFPACK, CHOLMOD, SPQR) and are called as any library is (see [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref)):
  the program sets them up the first time that it needs them, as Julia does (`LibSuiteSparse.init_suitesparse`, with the C library's allocators), and tells libblastrampoline what BLAS it forwards to, as
  it does for BLAS. What is different: CHOLMOD's error says the code of the failure (a `CHOLMODException("CHOLMOD error (status -3)")`) and not its message, and the settings that CHOLMOD keeps for each task are the program's one.

Also: `sleep` (as `nanosleep`), `splice!`, and `string(a, b, ...)` / interpolation with a value of `Any` (`"x = $(x)"` where the type of `x` is not known) work.

## MPI

Programs that use [MPI.jl](https://github.com/JuliaParallel/MPI.jl) compile, and run on several processes with `mpiexec`:

```julia
using MPI, StaticCompilerOverrides

function main(args::Vector{String})
    MPI.Init()
    comm = MPI.COMM_WORLD
    rank, size = MPI.Comm_rank(comm), MPI.Comm_size(comm)
    total = MPI.Allreduce(rank + 1, +, comm)
    x = Float64[10rank + i for i in 1:4]
    received = zeros(4)
    MPI.Sendrecv!(x, received, comm; dest = mod(rank + 1, size), source = mod(rank - 1, size))
    println("rank ", rank, " of ", size, ": total = ", total, ", received ", received)
    MPI.Finalize()
    return 0
end

compile_executable(main, (Vector{String},), "build", "ring")
# $ mpiexec -n 3 ./build/ring
```

The MPI library is a library that the program calls like any other (see [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref)): the one that MPI.jl is set to use (`MPICH_jll` by default, or a system one
through `MPIPreferences`), opened from the path that it has when compiling, or from the folder `lib` next to the program with `libraries = :bundle`. Run it with the `mpiexec` of the same library (`MPI.mpiexec()` has the environment that
the library needs). The point-to-point and collective operations (`Send`, `Recv!`, `Sendrecv!`, `Isend`, `Irecv!`, `Waitall`, `Probe`, `Bcast!`, `Reduce`, `Allreduce` with `+`, `*`, `max`, `min`, ..., `Gather`, `Scatter!`, `Gatherv!`, `Allgather`,
`Alltoall`, `Scan`, `Exscan`, `Barrier`), communicators (`Comm_split`, `Comm_dup`, which are freed by their finalizers, `Cart_create`), one-sided communication (`Win_create`, `Put!`, `Win_fence`), parallel files (`MPI.File`),
`Wtime`, the status of a message, and MPI errors (an `MPI.MPIError` that can be caught) are compared with Julia's in `test/packages/mpi.jl`. What is different:

* `MPI.Init` does not register `MPI.Finalize` to be called when the program ends (a compiled program does not run `atexit` functions): **call `MPI.Finalize()` at the end** (`finalize_atexit` is ignored).
* The handles of the constants (`MPI.COMM_WORLD`, `MPI.INT`, `MPI.SUM`, ...) are the numbers that the library has them as when compiling, which are the same on each run for the MPICH family (MPICH, Intel MPI, the MPI ABI libraries);
  they are addresses in Open MPI, which a compiled program can't use.
* Not supported: a reduction with an operator that is a function of yours (`MPI.Allreduce(x, f, comm)`): MPI.jl makes its C function with `@cfunction($w, ...)` of a value that holds the function, which Julia makes with a trampoline that it generates when the program runs (see [Callbacks: `@cfunction`](@ref)); and `MPI.send` / `MPI.recv` of any object (they use `Serialization`): use the
  operations on buffers (arrays and numbers).

## Finalizers

`finalizer(f, x)` works, for a Julia function `f` (a closure that captures values too) and a mutable object `x`, and for a C function (`finalizer(ptr, x)`, which is what `BigInt` has). When a collection finds
`x` unreachable, `f(x)` is run, as Julia does it: after the collection, at an allocation, one finalizer after another and not one inside another, and once. This is what the wrappers of libraries do to free what the
library allocated (a `Regex` made when the program runs, a sparse factorization, a PCRE or MPI handle). How it works, and what is different:

* The collector can't call the code of the program (it is compiled apart), so the object is kept and queued, and the program runs its finalizer when the collection is over: the call of `finalizer(f, x)` is a *site* of the
  types of `f` and `x`, which has a list of the finalizers that were registered at it (a function, and the address of the object, as a number: the list does not keep the object alive), and the linker writes a `switch` that gives
  each object to the function of its site (see `src/finalizers.jl`).
* A finalizer that throws is ignored (Julia prints the error). One that stores `x` somewhere (resurrection) is run once; `x` stays alive, and a later collection frees it.
* Finalizers of the objects that are alive when the program ends are not run.
* The collector is conservative: an object that a word of the stack happens to have the address of is not freed by that collection (so a finalizer may run at a later collection than in Julia, or, for one of the last
  objects made, not at all in a short program). The collector zeroes the unused part of the stack before it looks at it, which is most of the cases.
* Memory that a library allocated is not counted by the collector, so an object that has a finalizer counts as 1 KiB of allocation towards the next collection.

## Random numbers

`Random.default_rng()` (a `TaskLocalRNG`) keeps its state in the current task, which does not
exist in compiled programs. It is replaced by a global xoshiro256++ state, seeded from the
operating system (`getentropy`) when first used, like Julia seeds a new process. `Random.seed!(rng,
seed)` works for explicitly constructed generators. The default generator is not thread-safe, as
there are no threads. `Random.seed!(seed)` on the default generator does not work yet.

## Code from packages

(The survey that this section reports is kept as tests, `test/packages` — Distributions.jl, NaNStatistics.jl and StatsBase.jl, each program compared with Julia — and
run on CI as a job of its own.)

Code of packages compiles like the code of Base: nothing is needed from the package. What packages do that Base's code seldom does is
handled here, found by compiling [Distributions.jl](https://github.com/JuliaStats/Distributions.jl),
[NaNStatistics.jl](https://github.com/brenhinkeller/NaNStatistics.jl) and [StatsBase.jl](https://github.com/JuliaStats/StatsBase.jl):

* **Logging.** `@warn`, `@info` and `@error` write to the standard error, as the default logger of Julia does to something that is not a terminal
  (`┌ Warning: message`, the keywords as `│   key = value`, and `└ @ file:line`). `@debug` is off, as it is in Julia without `JULIA_DEBUG`, and the code of it is not in
  the binary. There is one logger (`with_logger` and `global_logger` have no effect), and `maxlog` is not kept: the message is written each time.
* **`invokelatest`.** `invokelatest(f, args...)` (and `@invokelatest f(args...)`) is the call `f(args...)`: there are no newer methods in a program. The keyword
  form (`invokelatest(f, x; k = 1)`) is not supported.
* **`@assert cond "message $x"`** works (the message is a `String`, made when the assertion fails).
* **Deprecated methods** can be called: the warning (`Base.depwarn`) is not shown, as it is not in Julia by default.
* **Functions of libraries that a package calls by the name of the library** (`ccall((:erfc, libopenlibm), ...)`, as SpecialFunctions.jl, which Distributions.jl
  uses, does). The functions of the math library of the machine are linked by name: the values can differ from openlibm's in the last bit. Those of
  other libraries (OpenSpecFun, Rmath, GMP, ...) are looked up when the program runs (see [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref)):
  by default the binary needs the file at the **path that the library had when compiling**, as it needs libblastrampoline for BLAS; `libraries = :bundle` copies them next to the program.
* **`IdDict`** works: the table is kept with Julia code, with the address of an object as its hash. What is not a mutable object all has one hash, so an `IdDict` with many
  keys that are numbers is slow.
* **`deepcopy`** works for any struct, array, dictionary, tuple or string, with shared and cyclic references kept as in Julia. Base reads the fields of a struct by a number that
  is only known when the program runs; here each type is copied field by field, each of its own type, made when compiling (`src/deepcopy.jl`). A field of the type `Any` or of an
  abstract type is copied over the registered types (see [`add_dispatch_candidates!`](@ref)). A method of `deepcopy_internal` that a package defines for its own type can't be used:
  compiling warns, and the program stops if it reaches the copy of such a type (it is not copied field by field, which would be a different result). Locks and `SimpleVector`s are not supported.
* **`reshape(x, :, n)`**, and **functions and `Colon()` in messages** (`string(sin)`, `show(:)`).

Compiled and compared with Julia in the survey (the results rounded to 6 digits, because of the last bit of libm):

* **Distributions.jl**: 65 of 65 cases, from `pdf`, `cdf`, `quantile`, `mean`, `var`, `entropy` for the usual distributions (`Normal`, `Gamma`, `Beta`, `TDist`, `Poisson`,
  `Binomial`, `Categorical`, `MvNormal`, `Dirichlet`, `Multinomial`, truncated and mixture models, ...), to `rand` with a generator that is given (`rand(Xoshiro(1), Normal())`),
  `fit`, `loglikelihood` and `kldivergence`.
* **NaNStatistics.jl**: all the cases of the survey (`nanmean`, `nanstd`, `nanmedian`, `nanquantile`, `nanpctile`, `nancov`, `nancor`, `movmean`, `histcounts`, `nanbinmean`, `nansort!`, ...)
  but `nanmean(A; dim = (1, 2))`: with the dimensions as a tuple the result is an `Array` of a size that is only known when the program runs (a function
  that is not type-stable), see [Dynamic dispatch on abstract types and on `Any`](@ref).
* **StatsBase.jl**: 92 of the 97 cases of the survey, of which 4 were not valid in Julia either. Weighted and unweighted `mean`, `var`, `std`, `median`, `quantile`,
  `skewness`, `kurtosis`, `mad`, `iqr`, `cor`, `cov`, `autocor`, `pacf`, `corspearman`, `corkendall`, ranks, `countmap`, `proportionmap`, `entropy`, `kldivergence`, `Histogram`, `ecdf`,
  `zscore` and `ZScoreTransform`, `sample` and `wsample` (with and without replacement, weighted) with a generator that is given, ... The one that doesn't: `summarystats` (it splats a
  `Vector` of a length that is not known into a constructor, `SummaryStats(m, sd, qs..., n)`).

* **DataStructures.jl**: 47 of 47 cases of the survey: `Stack`, `Queue`, `Deque`, `CircularBuffer`, `CircularDeque`, `MutableLinkedList`, `list`; `BinaryHeap` (min, max, custom order, mutable), `PriorityQueue`;
  `DefaultDict`, `counter`, `OrderedDict`, `OrderedSet`, `RobinDict`, `SwissDict`, `MultiDict`, `SparseIntSet`; `SortedDict`, `SortedSet`, `SortedMultiDict` (with semitokens and ranges); `IntDisjointSet`,
  `DisjointSet`, `FenwickTree`; and the balanced trees `AVLTree`, `RBTree` and `SplayTree`, whose nodes keep `Union{Node,Nothing}` fields. The methods that DataStructures has deprecated still work (the warning is not in the program).

* **StaticArrays.jl**: 27 of 27 cases of the survey: `SVector`, `MVector`, `SMatrix`, `MMatrix` and `SArray` (arithmetic, broadcasts, `map`, `push` and `pop`, `vcat` and `hcat`, `sort`, as `Dict` keys,
  in a `Vector`), `FieldVector` structs, the macros `@SVector` and `@SMatrix`, and `det`, `inv`, `\`, `eigvals`, `qr`, `svdvals`, `cholesky` and `lu` of small matrices.
* **OrderedCollections.jl**: 12 of 12 cases: `OrderedDict` (insertion, deletion, order of iteration, `merge`, `sort`, `pop!`), `OrderedSet` and `LittleDict`. The one that doesn't: `freeze` (it makes a tuple
  that has as many elements as the dictionary has, which is not known until the program runs).

* **Graphs.jl**: 42 of 42 cases of the survey: `SimpleGraph` and `SimpleDiGraph` (building, querying, subgraphs, the generators, `erdos_renyi` with a seed), `bfs_tree`, `dfs_tree`, `dijkstra`, `bellman_ford`,
  `floyd_warshall`, `a_star`, connected and strongly connected components, `topological_sort`, `kruskal_mst` and `prim_mst`, `maximal_cliques`, `greedy_color`, `label_propagation`, `pagerank`, `betweenness_centrality`,
  `closeness_centrality`, `eigenvector_centrality`, and the adjacency and Laplacian matrices.

* **Parsers.jl** (version 3): 40 of 40 cases of the survey: `parse` and `tryparse` of integers of every width (with `base` and `groupmark`), `Float16`, `Float32` and `Float64` (with `decimal`, hexadecimal floats, `Inf` and `NaN`),
  `Bool` (with other spellings), `Date`, `DateTime` and `Time` (with a format), `UUID`, `BigInt` and `BigFloat`, from strings and from spans of bytes; and `parsenext` and the kernels (`parseint`,
  `parsefloat`) that a reader of files is made of, in a loop over the fields of a line. The results of the floats are the same to the last bit as Julia's.

* **[Thermochron.jl](https://github.com/brenhinkeller/Thermochron.jl)** (forward models; 19 cases in the survey): helium diffusion (`SphericalHe`, `PlanarHe`, `ZirconHe`, `ApatiteHe` with RDAAM and ZRDAAM
  annealing, `SphericalAr`), fission track ages (`ZirconFT`, `ApatiteFT` with the Ketcham and Yamada/Guenthner models), vitrinite reflectance with a `NielsenBasinRo` that is a constant, and
  `model!` over a `Vector` of one concrete type of chronometer (`Vector{ApatiteHe{...}}`), with the chronometers built when compiling or by the program. Not yet: `model!` over a vector
  of chronometers of several types (`AbsoluteChronometer`, `FissionTrackSample`), because `model!` prints chronometers in a debugging message (`@info chrons[imax]`) and takes `argmax` over a union of many types, both dynamic
  (`eltype(c) <: C` now works, see [Binary size](@ref)); `NielsenBasinRo()` built by the program (it splats a vector into a tuple); and the MCMC functions, which are not tried yet.

* **[Isoplot.jl](https://github.com/brenhinkeller/Isoplot.jl)** (28 of 29 cases of the survey, after the changes below; `metropolis_min` compiles, but draws from the global generator, so its numbers are not
  Julia's): the weighted means, `mswd`, `chauvenet`, `yorkfit`, `lsqfit`, `mcleanfit`, `isochron`, the concordia functions (`age`, `discordance`, `isconcordant`, `upperintercept`, `ageconcordia`),
  `stacey_kramers`, `CI`, `Age`, `rand` of an analysis with a generator that is given, `distwmean` and `Measurement` arithmetic. Written with sizes that are only known when the
  program runs, five things did not compile, and were made to by small changes to a copy of the package: `Analysis(μ, Σ)` of a `Vector` and a `Matrix` is an `Analysis{length(μ)}` (given
  `SVector`s, whose length is in the type, it compiles); `SVector{npoints}` in `Ellipse` with a number of points that is a keyword (a `Val`, `Ellipse(d, Val(50))`); `ntuple(f, length(x))` of a
  `Vector` in `yorkfit` and `distwmean` (a `Tuple` or `SVector` of analyses compiles); `eigen` of an `SMatrix` that has complex eigenvalues for all that the compiler can tell
  (`eigen(Symmetric(Σ))`); and a local function that returns a number or a tuple depending on an argument (`mcleanfit`), which is two functions.

## Known limitations

What does not work yet, or works differently from Julia, gathered in one place. The sections above say more about each.

**Platforms**

* **macOS and Linux** only for the collector (`gc = true`); elsewhere it is off by default, and `gc = true` is an error. **Linux is
  tested on CI** (x86 and aarch64), not by hand: the collector depends on the layout of the stack and `setjmp` of the C library, and BLAS on `dlopen`.
* **The host is the target.** The heap and the runtime are made for the machine that compiles, so cross-compiling (a `target` that is
  not the host) is not supported.
* BLAS and LAPACK need LBT and the libraries that back it **at the same paths when the program is run** (see
  [Linear algebra and BLAS](@ref)); they are not in the binary. The same is true of any other library that the program calls, unless `libraries = :bundle`
  is used (see [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref)); BLAS is not bundled yet.

**Refused, because the answer would otherwise differ from Julia's**

* **Constant tables hashed by address.** A `const` `Dict` or `Set` whose keys are mutable objects (or hold one) with no `hash` method of
  their own, and any non-empty `IdDict`, are made in Julia with the addresses of their keys, which are not the addresses of the copies in the binary: a
  lookup would quietly find nothing. Compiling such a constant is an error that says so. Define `Base.hash` (and `==`) for the key type, or make the table
  when the program runs (a table that is made by the program is fine).
* **`deepcopy` of a type with a package's own `deepcopy_internal`.** The copy here is made field by field, which is not what that method does, so
  compiling warns, and the program stops if it reaches the copy.
* **Writes that fail.** A write, `flush` or `close` that libc reports as failed (a full disk, a closed pipe) throws, as in Julia. And if the system
  has no entropy for the default random number generator, the first `rand()` throws, rather than the program using a fixed seed (`Random.seed!` makes
  one that is meant to be fixed).
* Loops with `@simd` (so `sum`, `dot`, `mean`, ...) are vectorized and their reductions reordered, as in Julia, so the results are the same as
  Julia's, to the last digit, when it is run on the same machine type; other machines (SIMD widths) may differ in the last digits, in Julia as here.

**Standard libraries** (a survey of them is kept in `test/packages`, and what does not work, and what happens then, in `test/core/limitations.jl`)

* Work: Base64 (of a string or bytes), CRC32c, SHA, UUIDs (`uuid4()` too), `Random.RandomDevice`, Mmap (`Mmap.mmap(path, Vector{T}, dims, offset)`: the memory is not unmapped before the program ends), Statistics, Random, Printf, Logging (`NullLogger`), Dates, SparseArrays (with the factorizations), most of LinearAlgebra (`exp`, `sqrt`, `log` and powers of a matrix, `eigen`, `svd`, `qr`,
  `cholesky`, `lu`, `schur`, `ordschur`, `hessenberg`, `inv`, `det`, `\`, `opnorm`, ...), Sockets' address types, and the file system (see [The file system](@ref)).
* Do not: `Unicode.normalize`, `graphemes` and `isequal_normalized` (the tables are in libjulia's copy of utf8proc, which is not a library of its own); `readdlm` / `writedlm`; `@time` and `@allocated` (use `@elapsed`);
  `TOML.parse` (the parser keeps a `Module`); `Markdown` compiles, and stops when it is run (its parser needs Julia's own); `Mmap` of an open stream, and anonymous ones (only the files that are named by their path are mapped); `Test` (`@test` and `@testset`); `with_logger` with a logger other than `NullLogger`; starting other programs;
  `Base64` of anything but a string or bytes; `atexit` (the function would not be run, so the program stops when it is registered, except for SuiteSparse's own).

**Threads, tasks and `eval`**

* There are **no tasks, `Channel`s, `@async` or `Threads.@spawn`**, no `eval`, and no keyword form of `invokelatest`; **`@cfunction`** of a function with captured state (a closure over a variable) does not work (see [Callbacks: `@cfunction`](@ref)). (`Regex`, `BigInt` and `BigFloat` work: see
  [Libraries: `BigInt`, `BigFloat`, `Regex`, JLLs and libraries of your own](@ref).)
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
* `titlecase` of a string (it needs the grapheme breaks of utf8proc),
  the `MersenneTwister` generator, and `Random.seed!(seed)` of the default generator need things of libjulia that are not there.

* **Tuples that have a `Union` as an element** (`Tuple{Union{Vector{Float64},Vector{ComplexF64}},Int}`: what a function returns when the type of one of two values depends on the data) are made by Julia
  with the types that the values have when the program runs, which an executable can't make. They are fine when the function that makes them is inlined (the tuple is not made), which the
  compiler favors for them. A tuple that is returned by a function that is not inlined, or that is stored in an array or a `Dict`, is rejected when compiling; `enumerate` and `zip` of a
  `Union` of tuples of different types compile, and stop when they are run.

**What a binary starts with**

* **What the compiling Julia has is copied.** A `const` container, a `Ref`, a string, ... is in the binary as it was when compiling, and
  the program changes its own copy (so `ARGS` is set by the program, from its command line; and a global that the program changes
  does not change the Julia that compiled it). Only what is of a type that can be reproduced is copied: not a `Module`, a `Task`, ...
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
* **`rand` without a seed** gets its state from the operating system (`getentropy`); if that fails the first `rand()` throws, rather than
  giving the same stream each time. `RandomDevice` and `uuid4()` read `getentropy` at each call.
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
