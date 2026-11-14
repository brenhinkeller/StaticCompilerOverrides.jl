# Strict mode and method tables: code that can't work as a standalone binary is rejected when compiling, with a message that says why; the overrides of this package are used by its
# entry points and no others.

# The method table of this package does not contain StaticCompiler's overrides of the error
# helpers (which print and exit), so that errors can be caught; and StaticCompiler's does.
@testset "Method tables" begin
    SC = StaticRuntime.StaticCompiler
    domain_error(x::Int) = Base.Math.throw_complex_domainerror(:sqrt, x)
    function uses_quirk(table)
        ir = SC.GPUCompiler.JuliaContext() do ctx
            mod = static_llvm_module(domain_error, Tuple{Int}; method_table = table)
            try string(mod) finally SC.LLVM.dispose(mod) end
        end
        return occursin("requires a complex input", ir) # the message of the override in quirks.jl
    end
    @test !uses_quirk(StaticRuntime.method_table)
    @test uses_quirk(SC.method_table)
end

# Code that can't work as a standalone binary is rejected when compiling, rather than crashing
# (or silently misbehaving) when it is run, unless that is asked for
@testset "Strict mode" begin
    # the type of the stream is not known when compiling (an abstract type that has too many subtypes, none of which is registered: dynamic dispatch)
    printing() = (io = Base.inferencebarrier(STDOUT)::IO; println(io, "a"); 1)
    main = StaticRuntime.make_main(printing)
    compile(; kwargs...) = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)); kwargs...)

    err = try compile(); nothing catch e; e end
    @test err isa UnsupportedCodeError
    @test !isempty(err.dynamic)
    @test occursin("ijl_apply_generic", sprint(showerror, err)) # says which, and what to do
    @test occursin("strict = false", sprint(showerror, err))
    @test "ijl_apply_generic" in undefined_symbols(printing)    # reported by the diagnostics too

    # and where in the Julia code the call is: the function, the types of its arguments (`<unknown type>` for an argument that is not known), the source line, and the way from the entry point
    msg = sprint(showerror, err)
    @test occursin("Where in the code", msg)
    @test !isempty(err.sites) && any(((_, sites),) -> any(s -> !isempty(s.path) && !isempty(s.frames), sites), err.sites)
    @test occursin("reached through", msg) && occursin(".jl:", msg)

    # the global `stderr` has the abstract type `IO`: the message says to use `STDERR`
    uses_stderr() = (println(stderr, "message"); 1)
    stderr_main = StaticRuntime.make_main(uses_stderr)
    err2 = try Base.invokelatest(compile_executable, stderr_main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(stderr_main))); nothing catch e; e end
    @test err2 isa UnsupportedCodeError
    @test occursin("STDERR", sprint(showerror, err2))
    @test !isempty(err2.pointers) # references to Julia objects by their address are reported too

    # strict = false compiles code that has dynamic dispatch anyway (and the call aborts the program if
    # it is reached); `allow` accepts specific runtime functions, and keeps the check for the rest
    dynamic() = (io = Base.inferencebarrier(STDOUT)::IO; println(io, 3); 1)
    dyn_main = StaticRuntime.make_main(dynamic)
    compile_dynamic(; kwargs...) = Base.invokelatest(compile_executable, dyn_main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(dyn_main)); kwargs...)
    @test_throws UnsupportedCodeError compile_dynamic()
    @test isfile(compile_dynamic(strict = false))
    @test isfile(compile_dynamic(allow = ("ijl_apply_generic",)))
    # (not enough when there are other problems, here references to Julia objects by their address)
    @test_throws UnsupportedCodeError Base.invokelatest(compile_executable, stderr_main, (Int, Ptr{Ptr{UInt8}}), mktempdir(),
                                                        string(nameof(stderr_main)); allow = ("ijl_apply_generic",))
    # code that is supported is not affected
    ok() = 1
    ok_main = StaticRuntime.make_main(ok)
    @test isfile(Base.invokelatest(compile_executable, ok_main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(ok_main))))
end

# An entry point that does not infer to a concrete type says where in the program that comes from
inference_leaf(x::Int) = x > 0 ? x : error("negative")
inference_always() = inference_leaf(-1) + error("never")
@testset "Entry points that do not infer to a concrete type" begin
    function message(f)
        main = StaticRuntime.make_main(f)
        err = try
            Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)))
            nothing
        catch e
            e
        end
        return err, err === nothing ? "" : sprint(showerror, err)
    end
    err, text = message(inference_always)
    @test err isa InferenceError
    @test err.rt === Union{}
    @test occursin("inference_always()", text) && occursin("inference_leaf(::Int64)", text) && occursin("always throws", text)
end
