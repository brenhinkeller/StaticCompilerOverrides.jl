using Libdl

# Libraries that the program calls: by name (`"libz"`), BigInt and BigFloat (GMP and MPFR), Regex (PCRE2).

@testset "Libraries" begin
    s(x) = Base.inferencebarrier(x)::String
    sy(x) = Base.inferencebarrier(x)::Symbol

    @testset "functions of a library given by name" begin
        check_cases(["crc32 of libz" => () -> Int(ccall((:crc32, "libz"), Culong, (Culong, Ptr{UInt8}, Cuint), 0, pointer("hello"), 5))])
    end

    @testset "BigInt" begin
        fib(n) = (a = big(0); b = big(1); for _ in 1:n; a, b = b, a + b; end; a)
        churn() = (acc = 0; for i in 1:2000; acc += Int(factorial(big(40 + i % 7)) % (1000 + i)); end; acc)
        check_cases([
            "power, rem"   => () -> Int(big(2)^70 % 1000),
            "factorial"    => () -> Int(factorial(big(20)) ÷ big(10)^15),
            "fibonacci"    => () -> Int(fib(500) % 1000003),
            "string"       => () -> length(string(big(7)^200)),
            "parse"        => () -> Int(parse(BigInt, "123456789012345678901234567890") % 97),
            "comparisons"  => () -> (big(2)^100 > big(3)^60) + 10 * (big(5) == 5) + 100 * Int(isqrt(big(10)^30) % 1000),
            "many numbers" => churn,   # (the finalizers free what GMP allocated)
        ])
    end

    @testset "BigFloat" begin
        check_cases([
            "arithmetic" => () -> Int(floor(big(2.5) * big(4.0))),
            "sqrt"       => () -> Int(floor(sqrt(big(2)) * 1000)),
            "round"      => () -> Int(round(big(2.5))),
            "to Float64" => () -> Float64(sqrt(big(2))) > 1.41,
            "precision"  => () -> setprecision(() -> Int(precision(big(1.5))), BigFloat, 100),
        ]; broken = ("precision",))
    end

    @testset "Regex" begin
        check_cases([
            "match"         => () -> (m = match(r"b+", s("aabbb")); m === nothing ? 0 : length(m.match)),
            "no match"      => () -> match(r"z", s("aabbb")) === nothing ? 1 : 0,
            "occursin"      => () -> Int(occursin(r"^a+b", s("aabbb"))),
            "captures"      => () -> (m = match(r"(\d+)-(\d+)", s("tel 555-1234 x")); m === nothing ? 0 : parse(Int, m[1]) + parse(Int, m[2])),
            "named, string" => () -> (m = match(r"(?<k>[a-z]+)=(?<v>\d+)", s("key=42")); m === nothing ? 0 : parse(Int, m["v"])),
            "named, symbol" => () -> (m = match(r"(?<k>[a-z]+)=(?<v>\d+)", s("key=42")); m === nothing ? 0 : parse(Int, m[:v])),
            "replace"       => () -> length(replace(s("a1b22c333"), r"\d+" => "#")),
            "eachmatch"     => () -> count(_ -> true, eachmatch(r"\w+", s("one two three"))),
            "split"         => () -> length(split(s("a, b,c ,d"), r"\s*,\s*")),
            "made at run time" => () -> (m = match(Regex(s("x+y")), s("axxy")); m === nothing ? 0 : m.offset),
            "startswith"    => () -> Int(startswith(s("abc"), r"ab")),
            "unicode"       => () -> (m = match(r"é+", s("caféé!")); m === nothing ? 0 : length(m.match)),
            "caseless"      => () -> Int(occursin(r"HELLO"i, s("say hello"))),
        ])
    end

    @testset "A Symbol as a C string is the Symbol in the program" begin
        check_cases([
            "constant" => () -> Int(ccall(:strlen, Csize_t, (Cstring,), :abcd)),
            "run time" => () -> Int(ccall(:strlen, Csize_t, (Cstring,), sy(:abcde))),
        ])
    end

    # A library of our own, made with the C compiler of the system (the tests of it are skipped where there is none)
    cc = something(Sys.which("cc"), Sys.which("clang"), Sys.which("gcc"), Some(nothing))
    if cc === nothing
        @info "No C compiler: the tests of libraries of our own are skipped"
    else
        dir = mktempdir()
        write(joinpath(dir, "a.c"), "int lib_a_twice(int x) { return 2 * x; }\n")
        write(joinpath(dir, "b.c"), "int lib_a_twice(int);\nint lib_b_value(int x) { return lib_a_twice(x) + 1; }\n")
        ext = Libdl.dlext
        lib_a = joinpath(dir, "libtesta.$ext")
        lib_b = joinpath(dir, "libtestb.$ext")
        rpath = Sys.isapple() ? `-Wl,-rpath,@loader_path` : `-Wl,-rpath,\$ORIGIN`
        install_name = Sys.isapple() ? `-Wl,-install_name,@rpath/libtesta.$ext` : `-Wl,-soname,libtesta.$ext`
        run(`$cc -shared -fPIC -o $lib_a $(joinpath(dir, "a.c")) $install_name`)
        run(`$cc -shared -fPIC -o $lib_b $(joinpath(dir, "b.c")) -L$dir -ltesta $rpath`)
        global TEST_LIB_A = lib_a
        global TEST_LIB_B = lib_b
        function run_compiled(f; kwargs...)
            main = StaticCompilerOverrides.make_main(f)
            out = mktempdir()
            exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), out, string(nameof(main)); kwargs...)
            return out, exe
        end

        @testset "a library of the user's, by its path" begin
            f = () -> Int(ccall((:lib_a_twice, TEST_LIB_A), Cint, (Cint,), 21))
            @test static_status(f) == (:ok, "")
        end

        @testset "a library that needs another" begin
            f = () -> Int(ccall((:lib_b_value, TEST_LIB_B), Cint, (Cint,), 20))
            @test static_status(f) == (:ok, "")
        end

        @testset "libraries = :bundle" begin
            f = () -> Int(ccall((:lib_b_value, TEST_LIB_B), Cint, (Cint,), 20))
            out, exe = run_compiled(f; libraries = :bundle)
            bundled = sort(readdir(joinpath(out, "lib")))
            @test bundled == ["libtesta.$ext", "libtestb.$ext"]
            # the program, and its libraries, in another folder, and the libraries where they were are gone: the program uses its own
            moved = mktempdir()
            cp(out, moved; force = true)
            mkdir(joinpath(dir, "away"))
            for lib in (lib_a, lib_b)
                mv(lib, joinpath(dir, "away", basename(lib)))
            end
            try
                @test read(`$(joinpath(moved, basename(exe)))`, String) == string(41, "\n")
            finally
                for lib in (lib_a, lib_b)
                    mv(joinpath(dir, "away", basename(lib)), lib)
                end
            end
        end

        @testset "a library that is not there is said, and not a crash" begin
            f = () -> Int(ccall((:lib_a_twice, TEST_LIB_A), Cint, (Cint,), 1))
            out, exe = run_compiled(f)
            mv(lib_a, lib_a * ".moved")
            try
                err = IOBuffer()
                proc = run(pipeline(ignorestatus(`$exe`); stderr = err))
                @test proc.exitcode != 0
                @test occursin("Cannot use a library", String(take!(err)))
            finally
                mv(lib_a * ".moved", lib_a)
            end
        end
    end
end

# Functions that are called by the name of a library (src/libraries.jl): libm's, and the ones of a library that is loaded when the program runs, from the path that it had when compiling
const TEST_MPFR = Libdl.LazyLibrary("libmpfr")
mpfr_version() = unsafe_string(ccall((:mpfr_get_version, TEST_MPFR), Cstring, ()))
const TEST_LIBM = Libdl.LazyLibrary(Base.libm_name)
@testset "Functions of libraries" begin
    # libm: called by name
    erfc_value(x) = ccall((:erfc, TEST_LIBM), Float64, (Float64,), x)
    f = () -> round(Int, 1e6 * erfc_value(Base.inferencebarrier(0.3)))
    @test static_result(f) == f()
    @test isempty(undefined_symbols(f) ∩ ["ijl_lazy_load_and_lookup", "ijl_load_and_lookup"])
    # another library: loaded when the program runs, from the path that it had when compiling
    if Libdl.dlopen("libmpfr", throw_error = false) !== nothing
        main = StaticCompilerOverrides.make_main(() -> (length(mpfr_version())))
        exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)))
        @test parse(Int, readchomp(`$exe`)) == length(mpfr_version())
    else
        @info "Skipping the test of another library: libmpfr is not found"
    end
end

@testset "A literal as a C string" begin
    check_cases(["ccall with a Cstring literal" => () -> Int(ccall(:strlen, Csize_t, (Cstring,), "hello"))]) # (the address of the literal is passed as a number)
end
