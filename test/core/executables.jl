# The executable that is made (compile_executable): its entry point with the arguments of the command line, the standard streams, the exit status, and the object files.

@testset "Entry point with arguments and standard streams" begin
    @eval function args_main(args::Vector{String})
        println(length(args))
        for arg in args
            println(arg)
        end
        println(length(ARGS))
        return length(args)
    end
    # (the `ARGS` of the program must not have the arguments of the Julia that compiled it: its vector is embedded as it is)
    push!(Base.ARGS, "an argument of the process that compiles")
    exe = try
        Base.invokelatest(compile_executable, args_main, (Vector{String},), mktempdir())
    finally
        pop!(Base.ARGS)
    end
    @test read(`$exe`, String) == "0\n0\n"
    @test read(ignorestatus(`$exe one two three`), String) == "3\none\ntwo\nthree\n3\n"
    @test run(ignorestatus(pipeline(`$exe a b`; stdout = devnull))).exitcode == 2 # the return value
    @test success(pipeline(`$exe`; stdout = devnull))

    # standard input
    @eval function stdin_main(args::Vector{String})
        total = 0
        while !eof(STDIN)
            total += read(STDIN, UInt8)
        end
        println(total)
        return 0
    end
    exe = Base.invokelatest(compile_executable, stdin_main, (Vector{String},), mktempdir())
    @test read(pipeline(`$exe`; stdin = IOBuffer("abc")), String) == "$(sum(codeunits("abc")))\n"
    @test read(pipeline(`$exe`; stdin = IOBuffer("")), String) == "0\n"

    @eval function readline_main(args::Vector{String})
        while !eof(STDIN)
            line = readline(STDIN)
            println(length(line), ": ", line)
        end
        return 0
    end
    exe = Base.invokelatest(compile_executable, readline_main, (Vector{String},), mktempdir())
    @test read(pipeline(`$exe`; stdin = IOBuffer("hello\nworld wide\n\nlast")), String) == "5: hello\n10: world wide\n0: \n4: last\n"
end

# The object files that are made for macOS say what system they are for (a "platform load command"), as the linker of recent versions of
# macOS warns about every one that doesn't
@static if Sys.isapple()
    @testset "Object files have a platform load command" begin
        dir = mktempdir()
        main = StaticRuntime.make_main(() -> 1)
        name = string(nameof(main))
        Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), dir, name)
        @test occursin("LC_BUILD_VERSION", read(`otool -l $(joinpath(dir, name * ".o"))`, String))
    end
end

# `small = true`: the file is smaller (on macOS the names of the functions and a segment of constants are left out; no collector in a program that allocates a finite amount), and the
# program does what it does
args_hello(args::Vector{String}) = (println("hello ", length(args)); 0)
@testset "small = true makes a smaller file" begin
    sizes = Int[]
    for small in (false, true)
        dir = mktempdir()
        exe = compile_executable(args_hello, (Vector{String},), dir, "args_hello"; small)
        @test readchomp(`$exe a b`) == "hello 2"
        push!(sizes, filesize(exe))
    end
    @test sizes[2] < sizes[1]
    # (a library can be called any number of times, so the collector stays: only the flags of the linker)
    dir = mktempdir()
    lib = compile_shlib(args_hello, (Vector{String},), dir, "args_hello_lib"; small = true)
    @test isfile(lib)
end
