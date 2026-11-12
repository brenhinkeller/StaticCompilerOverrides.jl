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

# `small = true`: the file is smaller (on macOS the names of the functions and a segment of constants are left out), and the
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
    # (a library: only the flags of the linker)
    dir = mktempdir()
    lib = compile_shlib(args_hello, (Vector{String},), dir, "args_hello_lib"; small = true)
    @test isfile(lib)
end

# Julia marks the loads of the GC roots of a call as invariant, which is true where the slots of the frames are zeroed after the optimizer has run, and not here, where they are lowered first: a pass that runs
# after it (`GVN`) took the zero that is stored first for what the load gives, and the pointer to the characters of a `SubString` was null (`drop_invariant_root_loads!`)
parse_substring(args::Vector{String}) = (n = parse(Int, args[1]); s = 0; for i in 1:n; str = string("item", i, ":", i * 3); k = findfirst(':', str); s += parse(Int, SubString(str, k + 1)) + length(str); end; println(s); 0)
@testset "No load of a root is marked invariant" begin
    # (the loads of globals are: `jl_nothing` does not change)
    ir = sprint(io -> static_code_llvm(parse_substring, (Vector{String},); io))
    invariant = [l for l in split(ir, '\n') if occursin("!invariant.load", l)]
    @test all(l -> occursin(r"= load [^,]+, ptr (@|getelementptr[^,]*@)", l), invariant)
    # and a pass that is run after linking gives the answer that the program gives without it
    postprocess(mod) = (StaticRuntime.Runtime.link_runtime!(mod; bounded = true); LLVM.run!("function(gvn)", mod); mod)
    dir = mktempdir()
    exe = compile_executable(parse_substring, (Vector{String},), dir, "parse_substring"; llvm_postprocess = postprocess)
    expected = (s = 0; for i in 1:20; str = string("item", i, ":", i * 3); k = findfirst(':', str); s += parse(Int, SubString(str, k + 1)) + length(str); end; s)
    @test readchomp(`$exe 20`) == string(expected)
end

# The type-based aliasing of Julia's IR (`!tbaa`) is not true after the inliner and the passes after it have changed the IR: a copy of an immutable tuple that a `memcpy` made, which `GVN` took for memory
# that nothing wrote (`drop_type_based_aliasing!`): the second `@printf` into a file threw an exception
two_printf(args::Vector{String}) = (path = string(args[1], "/two_printf.txt"); open(path, "w") do io; Printf.@printf(io, "%s %d %5.2f\n", "third", 3, 3.14159); Printf.@printf(io, "%s=%d\n", "four", 4); end; print(read(path, String)); 0)
@testset "Two @printf into a file, with the pipeline after linking" begin
    for (name, post) in (("the default", nothing), ("GVN", mod -> (StaticRuntime.Runtime.link_runtime!(mod; bounded = true); LLVM.run!("function(gvn)", mod); mod)))
        dir = mktempdir()
        exe = post === nothing ? compile_executable(two_printf, (Vector{String},), dir, "two_printf") :
                                 compile_executable(two_printf, (Vector{String},), dir, "two_printf"; llvm_postprocess = post)
        @test readchomp(`$exe $dir`) == "third 3  3.14\nfour=4"
    end
end
