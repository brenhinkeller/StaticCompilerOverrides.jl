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
    for (name, post) in (("optimize = true", nothing), ("GVN after dropping the aliasing", mod -> (StaticRuntime.Runtime.link_runtime!(mod; bounded = true); StaticRuntime.Runtime.drop_type_based_aliasing!(mod); LLVM.run!("function(gvn)", mod); mod)))
        dir = mktempdir()
        exe = post === nothing ? compile_executable(two_printf, (Vector{String},), dir, "two_printf"; optimize = true) :
                                 compile_executable(two_printf, (Vector{String},), dir, "two_printf"; llvm_postprocess = post)
        @test readchomp(`$exe $dir`) == "third 3  3.14\nfour=4"
    end
end

# The code that runs only to stop with an error (the constructors of exceptions and their messages) is optimized for size: `minsize`, which also makes the machine outliner work on it. The code of the program is not.
@testset "Code for errors is optimized for size" begin
    ir = sprint(io -> static_code_llvm(parse_substring, (Vector{String},); io))
    groups = Dict(m.captures[1] => m.captures[2] for m in eachmatch(r"^attributes #(\d+) = \{ ([^}]*) \}"m, ir))
    minsize(line) = (m = match(r"\) [^{]*#(\d+) \{", line); m !== nothing && occursin("minsize", get(groups, m.captures[1], "")))
    defined = [l for l in split(ir, '\n') if startswith(l, "define ")]
    @test any(l -> occursin("throw_parseint_error", l) && minsize(l), defined) # (only called to throw)
    @test any(l -> occursin("BoundsError", l) && minsize(l), defined)
    @test !any(l -> occursin("@julia_parse_substring", l) && minsize(l), defined) # (the program)
    @test !any(l -> occursin("@julia__parse_", l) && minsize(l), defined) # (what `parse` does when it does not throw)
end

# On Apple Silicon, a floating-point constant is loaded from the constant pool, as the C library does. With the CPU model of the Apple cores (`fuse-literals`), the code generator makes each from a `mov`, three `movk` and a `fmov`, which makes the math functions (`log`, `exp`, `atan`, ...) 15% to 35% slower.
if Sys.isapple() && Sys.ARCH === :aarch64
    @testset "Constants of the math functions are loaded, not built" begin
        @eval constant_poly(x::Float64) = muladd(x, muladd(x, 0.6931471805599453, 0.2402265069591007), 0.0555041086648216)
        asm = sprint(io -> static_code_native(constant_poly, (Float64,); io))
        @test !occursin("movk", asm)
        @test occursin("ldr\td", asm) || occursin("ldp\td", asm) || occursin("ldr\tq", asm)
    end
end

# The three forms of the entry point: `main()`, `main(args)` and `main(argc, argv)`, and the exit status of each
@testset "Entry points: main(), main(args), main(argc, argv)" begin
    exit_code(exe, args...) = run(ignorestatus(pipeline(`$exe $args`; stdout = devnull))).exitcode

    # without arguments: the result of `f` that is an integer is the status, and anything else is 0 (a `println` that ends the function returns `nothing`)
    @eval no_args_nothing() = println("no arguments")
    @eval no_args_three() = (println("three"); 3)
    @eval no_args_cond() = (rand() < 2 ? 5 : 0)
    @eval no_args_arguments() = (print(length(ARGS)); 0)
    exe = Base.invokelatest(compile_executable, no_args_nothing, (), mktempdir())
    @test read(`$exe`, String) == "no arguments\n"
    @test exit_code(exe) == 0
    @test exit_code(exe, "a", "b") == 0
    exe = Base.invokelatest(compile_executable, no_args_three, (), mktempdir())
    @test read(ignorestatus(`$exe`), String) == "three\n"
    @test exit_code(exe) == 3
    exe = Base.invokelatest(compile_executable, no_args_cond, (), mktempdir())
    @test exit_code(exe) == 5
    # (`compile_executable(f)`: the types are `()`, and the name is that of the function)
    dir = mktempdir()
    exe = cd(dir) do
        Base.invokelatest(compile_executable, no_args_nothing)
    end
    @test basename(exe) == "no_args_nothing" && exit_code(exe) == 0
    # `ARGS` is empty without arguments, whatever the command line has
    push!(Base.ARGS, "an argument of the process that compiles")
    exe = try
        Base.invokelatest(compile_executable, no_args_arguments, (), mktempdir())
    finally
        pop!(Base.ARGS)
    end
    @test read(`$exe a b c`, String) == "0"

    # with `args`: `nothing` is 0 as well, and an integer is the status
    @eval args_nothing(args::Vector{String}) = println(length(args))
    exe = Base.invokelatest(compile_executable, args_nothing, (Vector{String},), mktempdir())
    @test read(`$exe a b`, String) == "2\n" && exit_code(exe, "a", "b") == 0

    # `main(argc, argv)` is C's: the integer that it returns is the status (`Int` or `Int32`)
    @eval raw_main(argc::Int, argv::Ptr{Ptr{UInt8}}) = (println(argc); Int32(4))
    exe = Base.invokelatest(compile_executable, raw_main, (Int, Ptr{Ptr{UInt8}}), mktempdir())
    @test read(ignorestatus(`$exe a b`), String) == "3\n"
    @test exit_code(exe, "a", "b") == 4
end
