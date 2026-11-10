# Files and streams (src/files.jl, src/io.jl): what a program does with files, compared with Julia's. The same function runs in Julia (with the streams of Base) and compiled (with libc's);
# they write and read files in different directories, and print what they find, which must be the same. Also the standard streams as files, binary data, and what is said of errors.

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

# Errors of libc that were ignored: a file that can't be written (a full disk) was closed without a word
@static if Sys.islinux()
    full_disk() = (io = open("/dev/full", "w"); write(io, "data"); close(io); 1)
    full_disk_flush() = (io = open("/dev/full", "w"); write(io, "data"); flush(io); close(io); 1)
    @testset "Write errors" begin
        @test static_status(full_disk)[1] == :runtime_error
        @test static_status(full_disk_flush)[1] == :runtime_error
    end
end

# A file that was closed has no `FILE*`: reading it was a call of libc with a null pointer
closed_read() = (path = "/tmp/static_overrides_closed_test.txt"; write(path, "abc"); io = open(path); close(io); try; read(io, UInt8); 0; catch; 1; end)
@testset "A file that is closed" begin
    @test static_status(closed_read)[1] == :ok
end
