# Dynamic dispatch on abstract types: resolved when compiling, by union splitting over the concrete subtypes (`src/dispatch.jl`)

abstract type DAnimal end
abstract type DPet <: DAnimal end
struct DDog <: DPet; age::Int; end
struct DCat <: DPet; age::Int; end
struct DCow <: DAnimal; weight::Float64; end
struct DFish <: DAnimal; n::Int; end
struct DHen <: DAnimal; eggs::Int; end
struct DBee <: DAnimal; hives::Int; end
dvalue(a::DDog) = a.age * 10
dvalue(a::DCat) = a.age * 20
dvalue(a::DCow) = round(Int, a.weight)
dvalue(a::DFish) = a.n
dvalue(a::DHen) = a.eggs + 1000
dvalue(a::DBee) = a.hives * 7
dkind(::DPet) = 1
dkind(::DAnimal) = 2
dname(a::DDog) = "dog"
dname(a::DCow) = "cow"
dname(a::DAnimal) = "other" # (the types without a method of their own)
dmix(a::DDog, b::DCat) = 1
dmix(a::DCat, b::DDog) = 2
dmix(a::DAnimal, b::DAnimal) = 3
dsize(a::DDog) = 1          # (results of different types)
dsize(a::DCow) = 2.5
dsize(a::DAnimal) = "big"
dany(x::Int) = 1
dany(x::Any) = 100
struct DUnregistered; v::Int; end
dnamed(x::Int) = x
dnamed(x::DUnregistered) = x.v
const DALL = DAnimal[DDog(3), DCat(2), DCow(450.5), DFish(12), DHen(5), DBee(2)]

abstract type DOpen end        # (a parametric subtype, whose instances can't be listed)
struct DOpenA{T} <: DOpen; x::T; end
struct DOpenB <: DOpen; x::Int; end
struct DOpenC <: DOpen; x::Int; end
struct DOpenD <: DOpen; x::Int; end
struct DOpenE <: DOpen; x::Int; end
dopen(a::DOpenA) = 1
dopen(a::DOpenB) = 2
dopen(a::DOpenC) = 3
dopen(a::DOpenD) = 4
dopen(a::DOpenE) = 5

@testset "Dispatch on abstract types" begin
    zoo() = DALL # (types that are not known when compiling)
    @testset "six types, two levels of abstract types" begin
        @test static_result(() -> (s = 0; for a in zoo(); s += dvalue(a); end; s)) == sum(dvalue, DALL)
        @test static_result(() -> sum(dvalue, zoo())) == sum(dvalue, DALL)
    end
    @testset "fallbacks and specificity" begin
        @test static_result(() -> sum(dkind, zoo())) == sum(dkind, DALL)
        @test static_result(() -> sum(a -> length(dname(a)), zoo())) == sum(a -> length(dname(a)), DALL)
    end
    @testset "two arguments" begin
        f() = (z = zoo(); s = 0; for a in z, b in z; s += dmix(a, b); end; s)
        @test static_result(f) == f()
    end
    @testset "results of different types" begin
        f() = (s = 0.0; for a in zoo(); r = dsize(a); s += r isa Int ? r : r isa Float64 ? r : length(r); end; s)
        @test static_result(() -> round(Int, f())) == round(Int, f())
    end
    @testset "Union{Nothing,T}, and a Dict of them" begin
        f() = (d = Dict{Int,DAnimal}(); d[1] = DALL[1]; d[2] = DALL[3]; s = 0; for (k, a) in d; s += k * dvalue(a); end; s)
        @test static_result(f) == f()
        g() = (x::Union{Nothing,DAnimal} = DALL[2]; x === nothing ? 0 : dvalue(x))
        @test static_result(g) == g()
    end
    @testset "abstract types that can't be listed stay dynamic (and are rejected)" begin
        f() = (v = DOpen[DOpenB(1), DOpenB(2)]; sum(dopen, v))
        @test static_status(f)[1] == :compile_error
        h() = (v = Any[1, 2.5]; sum(x -> x isa Int ? 1 : 2, v))
        @test static_status(h)[1] == :ok # (the tests of a type are not dispatch)
    end
    @testset "Any, over the registered types" begin
        # (new closures for each, so that nothing is taken from what was inferred for another)
        sum_any() = (v = Any[1, 2.5, 3, Float32(0.5)]; s = 0.0; for x in v; s += x; end; s)
        @test static_result(() -> round(Int, 10 * sum_any())) == round(Int, 10 * sum_any())
        plus_one() = (v = Any[1, 2.5, UInt8(3)]; Float64(v[1] + 1) + Float64(v[2] + 1) + Float64(v[3] + 1))
        @test static_result(() -> round(Int, 10 * plus_one())) == round(Int, 10 * plus_one())
        two_any() = (a = Any[1, 2.5]; Float64(a[1] + a[2]))
        @test static_result(() -> round(Int, 10 * two_any())) == round(Int, 10 * two_any())
        sorted_any() = (v = Any[3, 1.5, 2]; sort!(v); Float64(v[1]) * 10 + Float64(v[3]))
        @test static_result(() -> round(Int, sorted_any())) == round(Int, sorted_any())
        # printing a value of `Any`, as `show` does
        @test static_status(() -> (for x in Any[1, "a", 2.5, :s, nothing, 'c']; println(x); end; 1))[1] == :ok
        # a method for `Any` is called for the types that are registered as well
        any_fallback() = (v = Any[1, "a", 2.5]; s = 0; for x in v; s += dany(x); end; s)
        @test static_result(any_fallback) == any_fallback()
    end

    @testset "a type that is not registered is an error when running, and registering it" begin
        exe_output(f; kwargs...) = begin
            main = StaticCompilerOverrides.make_main(f)
            exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)); kwargs...)
            out = IOBuffer()
            p = run(ignorestatus(pipeline(`$exe`; stdout = out, stderr = devnull)))
            return p.exitcode, String(take!(out))
        end
        code, out = exe_output(() -> (v = Any[1, DUnregistered(1)]; s = 0; for x in v; s += dnamed(x); end; s))
        @test code == 1
        @test occursin("MethodError", out) && occursin("dnamed", out)
        add_dispatch_candidates!(DUnregistered)
        @test static_result(() -> (v = Any[1, DUnregistered(5)]; s = 0; for x in v; s += dnamed(x); end; s)) == 1 + 5
    end

    @testset "compiling says what was resolved over the registered types" begin
        # the messages about the registered types that compiling `f` logs (at the debug level, which `JULIA_DEBUG` shows)
        function dispatch_messages(f)
            logger = Test.TestLogger(min_level = Base.CoreLogging.Debug)
            Base.CoreLogging.with_logger(() -> static_result(f), logger)
            return filter(r -> occursin("registered types", r.message), logger.logs)
        end
        warned() = (v = Any[1, 2.5]; Float64(v[2] * 3))
        msgs = dispatch_messages(() -> round(Int, warned()))
        @test length(msgs) == 1 && msgs[1].level == Base.CoreLogging.Debug
        @test occursin("*", string(msgs[1].kwargs[:calls]))
        # (not shown unless asked for: nothing is logged at the default level)
        quiet() = (v = Any[1, 2.5]; Float64(v[2] * 5))
        @test_logs static_result(() -> round(Int, quiet()))
        # (not for types that are all listed)
        listed() = (z = DALL; sum(dvalue, z))
        @test isempty(dispatch_messages(listed))
    end

    # LLVM turns tests of a tag against the addresses of several types into a `switch` on `(tag + C)` rotated, with the numbers of the
    # cases computed from the addresses of the types *in this process*, and so it is not right for the tags of the binary (which are
    # the addresses of the types that are in it): all of the tests then fail, and the last method is called, for every type. The types
    # must not be numbers while the code is optimized, so what LLVM would have to do that with is not there.
    @testset "the tests of the types are not arithmetic on addresses" begin
        SC = StaticCompilerOverrides.StaticCompiler
        # (what the code has of the types when it has been optimized, which is when the runtime is added to it)
        type_numbers = Ref(-1)
        check(mod) = (type_numbers[] = length(StaticCompilerOverrides.Runtime.type_number_constants(mod)) +
                          count(a -> StaticCompilerOverrides.Runtime.object_type(a) === DataType, keys(StaticCompilerOverrides.Runtime.inttoptr_constants(mod)));
                      StaticCompilerOverrides.Runtime.link_runtime!(mod))
        main = StaticCompilerOverrides.make_main(() -> (s = 0; for a in DALL; s += dvalue(a); end; s))
        ir = SC.GPUCompiler.JuliaContext() do ctx
            mod = Base.invokelatest(static_llvm_module, main, Tuple{Int,Ptr{Ptr{UInt8}}}; llvm_postprocess = check)
            try string(mod) finally SC.LLVM.dispose(mod) end
        end
        @test type_numbers[] == 0 # (no addresses of types in the code that was optimized: they were globals that stood for them)
        @test !occursin("static_type_", ir) # (and they are the types that are in the binary now)
        # and the right method is called for each type
        @test static_result(() -> dvalue(DALL[2])) == dvalue(DALL[2])
        @test static_result(() -> dvalue(DALL[3])) == dvalue(DALL[3])
    end

    @testset "with the collector in stress mode" begin
        @test static_result(() -> sum(dvalue, zoo()); gc = 2) == sum(dvalue, DALL)
    end
end

# GPUCompiler's functions are specialized for the parameters of this package only: what StaticCompiler compiles on its own is unchanged
@testset "Our compilations only" begin
    SC = StaticCompilerOverrides.StaticCompiler
    splitting(params; kwargs...) = SC.GPUCompiler.inference_params(first(SC.static_job(identity, (Int,); params, kwargs...))).max_union_splitting
    # (also with our method table: it is the parameters that tell)
    @test splitting(SC.StaticCompilerParams(); method_table = StaticCompilerOverrides.method_table) == Core.Compiler.InferenceParams().max_union_splitting
    @test splitting(SC.StaticCompilerParams()) == Core.Compiler.InferenceParams().max_union_splitting
    @test splitting(StaticCompilerOverrides.OverridesParams(); method_table = StaticCompilerOverrides.method_table) >= StaticCompilerOverrides.SPLIT_LIMIT[]
    # the interpreter of our compilations is of a type of its own (so that the methods that change inference are for it only); StaticCompiler's own
    # compilations have GPUCompiler's interpreter, whatever is loaded
    interpreter(params; kwargs...) = SC.GPUCompiler.get_interpreter(first(SC.static_job(identity, (Int,); params, kwargs...)))
    @test interpreter(StaticCompilerOverrides.OverridesParams(); method_table = StaticCompilerOverrides.method_table) isa StaticCompilerOverrides.OverridesInterpreter
    @test !(interpreter(SC.StaticCompilerParams()) isa StaticCompilerOverrides.OverridesInterpreter)
    @test !(interpreter(SC.StaticCompilerParams(); method_table = StaticCompilerOverrides.method_table) isa StaticCompilerOverrides.OverridesInterpreter)
    # and they infer as they did: what `invokelatest` calls is not known to them
    plain_invokelatest() = Base.invokelatest(+, Base.inferencebarrier(1)::Int, 2)
    @test first(SC.static_code_typed(plain_invokelatest, ())).second === Any
    @test first(static_code_typed(plain_invokelatest, ())).second === Int
end

# A call with an argument of the type `Any` that has no method for any of the registered types (the only method is for a `Vector`, which
# is not one of them) is left to Julia, which tests the type of the argument: closing it to the registered types would make the call an
# error, and what calls it infer as `Union{}`.
only_vector(v::Vector) = length(v)
call_only_vector(x) = only_vector(x)
@testset "Calls over the registered types that no method fits" begin
    @test static_result(() -> call_only_vector(Base.inferencebarrier([1, 2, 3]))) == 3
end
