# What the manual says does not work, and what happens then: the program is refused when compiling, with a message that says why; or it compiles, and says so when it is run; or it does
# not do what Julia does, in the way that the manual says. A test here fails when one of them changes, in either direction: if something starts to work, move its case to the tests of the
# part of the language or of the library that it belongs to, and change the manual (the section "Known limitations"); if something that was refused now compiles and does not work, that is
# worse than the refusal.

@noinline recurse_forever(n::Int) = n == 0 ? 0 : 1 + recurse_forever(n - 1)
@noinline function nested_try(n::Int, v::Vector{Int}) # (the recursion is not a loop that the compiler can make: a value is kept after each call)
    n == 0 && return 0
    try
        r = nested_try(n - 1, v)
        push!(v, r)
        return r + 1
    catch
        return -1
    end
end

# what is said when a program is refused: it names the runtime that it needs, or the objects that it refers to by address, or the type that it does not infer
const REFUSAL = r"Julia runtime|by their address|does not infer to a concrete type"

@testset "Refused when compiling" begin
    cases = [
        # tasks and what is made of them (there is no scheduler)
        "@async and fetch"            => () -> fetch(@async 1 + 1),
        "Threads.@spawn and fetch"    => () -> fetch(Threads.@spawn 1 + 1),
        "a Channel"                   => () -> (c = Channel{Int}(2); put!(c, 1); take!(c)),
        "a Task that is scheduled"    => () -> (t = Task(() -> 1); schedule(t); wait(t); 1),
        # code that is made when the program runs
        "eval"                        => () -> Core.eval(Main, :(1 + 1)),
        # functions of the libraries that Julia has (utf8proc) and does not have as libraries of their own
        "Unicode.normalize"           => () -> length(Unicode.normalize(opaque("é"))),
        "graphemes"                   => () -> length(collect(graphemes(opaque("ab")))),
        "titlecase of a string"       => () -> length(titlecase(opaque("hello world"))),
        # the system, and the state of the compiling Julia
        "@time"                       => () -> (@time opaque(1) + 1; 0),
        "starting another program"    => () -> (run(`true`); 0),
        "TOML.parse"                  => () -> length(TOML.parse(opaque("a = 1"))),
        "a function that atexit calls, with state" => () -> (x = opaque(1); atexit(() -> println(x)); 0),
    ]
    for (name, f) in cases
        @testset "$name" begin
            status, detail = static_status(f)
            @test status == :compile_error
            @test occursin(REFUSAL, string(detail))
        end
    end
end

# these compile, and stop when they are run (the exit status says so; and the manual lists them as not supported)
@testset "Compiled, and failing when run" begin
    cases = [
        "Markdown"                    => () -> length(string(Markdown.parse(opaque("# a")))),
        "Mmap"                        => () -> (p = tempname(); write(p, "abc"); a = Mmap.mmap(p); Int(a[1])),
    ]
    for (name, f) in cases
        @testset "$name" begin
            @test static_status(f)[1] == :runtime_error
        end
    end
end

# what a program does that is not what Julia does, as the manual says (the section "Differences from Julia when the program runs")
@testset "Differences from Julia" begin
    @testset "locks do nothing: `islocked` is false" begin
        f = () -> (l = ReentrantLock(); lock(l); r = islocked(l); unlock(l); Int(r))
        @test static_status(f)[1] == :mismatch
    end
    @testset "no check of the size of the stack: infinite recursion is a crash, not a StackOverflowError" begin
        exe = compile_main(() -> recurse_forever(opaque(100_000_000)))
        p = run(pipeline(ignorestatus(`$exe`); stdout = devnull, stderr = devnull))
        @test !success(p)
        @test p.termsignal != 0 # (a segmentation fault, not an exit with a message)
    end
    @testset "at most 256 `try` blocks are active at once" begin
        run_nested(n) = (exe = compile_main(() -> (v = Int[]; nested_try(opaque(n), v) + length(v)));
                         out = IOBuffer(); p = run(pipeline(ignorestatus(`$exe`); stdout = out, stderr = out)); (p.exitcode, String(take!(out))))
        code, output = run_nested(100)
        @test code == 0
        code, output = run_nested(300)
        @test code != 0
        @test occursin("exception handler stack overflow", output)
    end
end
