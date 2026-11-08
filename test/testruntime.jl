# The minimal runtime of statically compiled code (src/runtime.jl): allocation without a GC, and
# exceptions. Included by runtests.jl.

# compile `main(argc, argv)`, run it, and return what it prints
function run_main(main; dir = mktempdir())
    exe = compile_executable(main, (Int, Ptr{Ptr{UInt8}}), dir, string(nameof(main)))
    return readchomp(`$exe`)
end

@testset "Runtime: allocation" begin
    # all of these used to fail to link
    @eval alloc_vector(argc::Int, argv::Ptr{Ptr{UInt8}}) = (printf(c"%d\n", sum(collect(1:argc+3))); 0)
    @eval alloc_push(argc::Int, argv::Ptr{Ptr{UInt8}}) = (v = Int[]; for i in 1:20; push!(v, i); end; printf(c"%d\n", sum(v)); 0)
    @eval alloc_dict(argc::Int, argv::Ptr{Ptr{UInt8}}) = (d = Dict(1 => 2, 3 => 4); printf(c"%d\n", d[1] + d[3]); 0)
    @eval alloc_string(argc::Int, argv::Ptr{Ptr{UInt8}}) = (printf(c"%d\n", length(string(12345))); 0)
    @test run_main(alloc_vector) == "10"
    @test run_main(alloc_push) == "210"
    @test run_main(alloc_dict) == "6"
    @test run_main(alloc_string) == "5"
end

@testset "Runtime: exceptions" begin
    @eval @noinline rt_thrower(x::Int) = x > 0 ? throw(ArgumentError("boom")) : x
    @eval rt_catch(argc::Int, argv::Ptr{Ptr{UInt8}}) = (r = try; rt_thrower(argc); catch; 7; end; printf(c"%d\n", r); 0)
    @eval rt_nocatch(argc::Int, argv::Ptr{Ptr{UInt8}}) = (r = try; rt_thrower(argc - 1); catch; 7; end; printf(c"%d\n", r); 0)
    @eval rt_finally(argc::Int, argv::Ptr{Ptr{UInt8}}) = (r = Ref(0); try; try; rt_thrower(argc); finally; r[] += 10; end; catch; r[] += 1; end; printf(c"%d\n", r[]); 0)
    @eval rt_rethrow(argc::Int, argv::Ptr{Ptr{UInt8}}) = (r = try; try; rt_thrower(argc); catch; rethrow(); end; catch; 5; end; printf(c"%d\n", r); 0)
    @test run_main(rt_catch) == "7"
    @test run_main(rt_nocatch) == "0"
    @test run_main(rt_finally) == "11"
    @test run_main(rt_rethrow) == "5"

    # no handler: report and exit with a failure status, rather than crashing
    @eval rt_uncaught(argc::Int, argv::Ptr{Ptr{UInt8}}) = (rt_thrower(argc); 0)
    exe = compile_executable(rt_uncaught, (Int, Ptr{Ptr{UInt8}}), mktempdir(), "rt_uncaught")
    p = run(ignorestatus(pipeline(`$exe`; stderr = devnull, stdout = devnull)))
    @test p.exitcode == 1
end

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

# The runtime allocates objects with a header before them, where compiled code writes the type tag.
# If it didn't, that would overwrite the metadata of the allocator, which makes the program fail now
# and then (depending on the layout of memory), so run a program that allocates, with the checks
# of the allocator of the system on (macOS, glibc)
@testset "Heap integrity" begin
    @eval function heap_work()
        total = 0
        for i in 1:300
            v = collect(1:i)
            push!(v, i)
            total += sum(v)
            total += length(string(i, "x", 1.5, :sym, 'c'))
            d = Dict{Int,String}()
            d[i] = string(i)
            d[-i] = "negative"
            total += length(d[i]) + length(d[-i])
            r = Ref(i)
            r[] += 1
            total += r[]
        end
        return total
    end
    @eval function heap_main(args::Vector{String})
        println(heap_work())
        return 0
    end
    exe = Base.invokelatest(compile_executable, heap_main, (Vector{String},), mktempdir())
    checks = ("MallocCheckHeapStart" => "1", "MallocCheckHeapEach" => "1", "MallocCheckHeapAbort" => "1",
              "MallocScribble" => "1", "MALLOC_CHECK_" => "3", "MALLOC_PERTURB_" => "165")
    expected = "$(Base.invokelatest(heap_work))\n"
    for _ in 1:5
        @test read(setenv(`$exe`, checks...), String) == expected
    end
end

# Files: what a program does with them is compared with Julia's. The same function runs in Julia (with
# the streams of Base) and compiled (with libc's); they write and read files in different directories,
# and print what they find, which must be the same
@testset "Files" begin
    @eval function file_demo(dir::String)
        path = string(dir, "/demo.txt")
        # write: do-block, print, println, @printf, write of a byte and of a string
        open(path, "w") do io
            println(io, "first line")
            print(io, "second ", 2, " line\n")
            Printf.@printf(io, "%s %d %5.2f\n", "third", 3, 3.14159)
            Printf.@printf(io, "%s=%d\n", "four", 4)
            write(io, 0x35)
            write(io, "5th\n")
        end
        # read it back in several ways
        text = read(path, String)
        println("text: ", length(text), " ", count(==('\n'), text))
        print(text)
        lines = readlines(path)
        println("lines: ", length(lines), " ", lines[end])
        open(path) do io
            println("first: ", readline(io))
            println("eof? ", eof(io), " position: ", position(io))
            n = 0
            while !eof(io)
                n += length(readline(io))
            end
            println("rest: ", n, " eof? ", eof(io))
            seekstart(io)
            println("again: ", read(io, UInt8), " ", read(io, UInt8), " position ", position(io))
            seekend(io)
            println("end: ", position(io), " ", filesize(io))
            seek(io, 6)
            println("seek: ", read(io, UInt8) == UInt8('l'))
        end
        # eachline, count, append, and a second file
        println("eachline: ", sum(length, eachline(path)))
        open(path, "a") do io
            println(io, "appended")
        end
        println("after append: ", length(readlines(path)))
        write(string(dir, "/other.txt"), "x = ", 42, "\n")
        println("other: ", read(string(dir, "/other.txt"), String))
        # a file that does not exist
        failed = try
            open(string(dir, "/missing/none.txt"))
            false
        catch
            true
        end
        println("missing: ", failed)
        return nothing
    end
    @eval file_main(args::Vector{String}) = (file_demo(args[1]); 0)

    host_dir, exe_dir = mktempdir(), mktempdir()
    expected = let (path, io) = mktemp()
        try
            redirect_stdout(io) do
                Base.invokelatest(file_demo, host_dir)
                flush(stdout)
            end
        finally
            close(io)
        end
        read(path, String)
    end
    exe = Base.invokelatest(compile_executable, file_main, (Vector{String},), mktempdir())
    @test read(`$exe $exe_dir`, String) == expected
    # and the files written are the same ones
    @test read(joinpath(host_dir, "demo.txt"), String) == read(joinpath(exe_dir, "demo.txt"), String)
    @test read(joinpath(host_dir, "other.txt"), String) == read(joinpath(exe_dir, "other.txt"), String)
end

# `printf` of StaticTools to a file, and the standard streams as files
@testset "Files: printf and the standard streams" begin
    @eval function printf_file_main(args::Vector{String})
        io = open(args[1], "w")
        printf(io, c"%s %d %5.2f %lld\n", c"x", 3, 3.14159, 10^12)
        printf(io, c"plain\n")
        close(io)
        println(isopen(io))
        return 0
    end
    dir = mktempdir()
    exe = Base.invokelatest(compile_executable, printf_file_main, (Vector{String},), mktempdir())
    @test read(`$exe $dir/out.txt`, String) == "false\n"
    @test read(joinpath(dir, "out.txt"), String) == "x 3  3.14 1000000000000\nplain\n"
end

# the forms of `readline`, `readlines` and `eachline` that read the standard input without naming it
@testset "Standard input without naming it" begin
    @eval function stdin_forms_main(args::Vector{String})
        first = readline()
        println("first: ", first)
        count = 0
        for line in eachline()
            count += 1
            println(count, ": ", line)
            count == 2 && break
        end
        rest = readlines()
        println("rest: ", length(rest), " ", isempty(rest) ? "" : rest[end])
        return 0
    end
    exe = Base.invokelatest(compile_executable, stdin_forms_main, (Vector{String},), mktempdir())
    input = "one\ntwo\nthree\nfour\nfive\nsix"
    @test read(pipeline(`$exe`; stdin = IOBuffer(input)), String) == "first: one\n1: two\n2: three\nrest: 3 six\n"
end

# Binary data: numbers and arrays of numbers, written and read back, compared with Julia's
@testset "Files: binary data" begin
    @eval function binary_demo(dir::String)
        path = string(dir, "/data.bin")
        open(path, "w") do io
            write(io, Int32(-5))
            write(io, 2.5)
            write(io, UInt8[1, 2, 3, 4])
            write(io, [10, 20, 30])
            write(io, 'x')
            write(io, UInt16(65535))
        end
        println("size: ", filesize(path))
        open(path) do io
            println(read(io, Int32), " ", read(io, Float64))
            bytes = read(io, 4)
            println(length(bytes), " ", sum(bytes), " ", bytes[end])
            v = Vector{Int}(undef, 3)
            read!(io, v)
            println(v[1], " ", v[2], " ", v[3], " ", read(io, Char), " ", read(io, UInt16), " ", eof(io))
            seekstart(io)
            println(length(read(io)), " ", position(io))
        end
        return nothing
    end
    @eval binary_main(args::Vector{String}) = (binary_demo(args[1]); 0)
    host_dir, exe_dir = mktempdir(), mktempdir()
    expected = let (path, io) = mktemp()
        try
            redirect_stdout(io) do
                Base.invokelatest(binary_demo, host_dir)
                flush(stdout)
            end
        finally
            close(io)
        end
        read(path, String)
    end
    exe = Base.invokelatest(compile_executable, binary_main, (Vector{String},), mktempdir())
    @test read(`$exe $exe_dir`, String) == expected
    @test read(joinpath(host_dir, "data.bin")) == read(joinpath(exe_dir, "data.bin"))
end

# The object files that are made for macOS say what system they are for (a "platform load command"), as the linker of recent versions of
# macOS warns about every one that doesn't
@static if Sys.isapple()
    @testset "Object files have a platform load command" begin
        dir = mktempdir()
        main = StaticCompilerOverrides.make_main(() -> 1)
        name = string(nameof(main))
        Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), dir, name)
        @test occursin("LC_BUILD_VERSION", read(`otool -l $(joinpath(dir, name * ".o"))`, String))
    end
end
