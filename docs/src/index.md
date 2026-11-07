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
`rand`/`randn` on the default RNG, and `try`/`catch`/`finally`/`rethrow` (including for errors thrown by Base, like `BoundsError`), in addition to what
StaticCompiler already handled (allocation-free numerical code, StaticTools types, and so on).
The tests in `test/corpus.jl` are the up-to-date list of the idioms that we check, and which of
them are known not to work yet.

!!! note "Printing does not work yet"
    `print`, `println`, `show`, `@printf` and the like are not supported yet, since there is no
    `stdout` (and `show` needs type information at run time). They are rejected when compiling
    (see strict mode). Use `printf` and `c"..."` from StaticTools in the meantime. Building strings
    with `string`, interpolation-free `sprint`, and so on does work.

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

* **`catch e; e isa T` is only reliable when the compiler knows the type of the exception.**
  Objects allocated by compiled code do not carry a type tag, so when more than one type can reach
  a `catch` (so that the type is only known at run time), `isa`/dispatch on `e` gives wrong
  answers instead of failing. Catching without looking at the exception, or where only one type
  can be thrown, is fine. This test is recorded as broken in `test/runtests.jl`.
* Code that needs dynamic dispatch, or other things from the Julia runtime, is rejected when
  compiling (see strict mode). With `strict = false`, it compiles and aborts with
  `Dynamic behavior is not supported in standalone binaries (...)` if the call is reached.

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
