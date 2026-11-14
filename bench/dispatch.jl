# Measurements of what dynamic dispatch costs: the time that it takes to compile a program, the size of it, how long it runs, and what was split (`src/inference/dispatch.jl`). A tool to run by hand, not part of the tests:
#
#     julia +1.14 --project=. bench/dispatch.jl list
#     julia +1.14 --project=. bench/dispatch.jl run NAME             # one program, in a process of its own: a line of `key=value`
#     julia +1.14 --project=. bench/dispatch.jl all results.txt      # all of them (each in its own process), a table, and the lines kept in a file
#     julia +1.14 --project=. bench/dispatch.jl compare base.txt new.txt
#
# `splits` is the number of different calls that were closed to unions of types, and `nominal` the product of the numbers of types of their arguments: not the number of cases that were made (Julia splits a call in cases only when its cost is
# at most `max_union_splitting`, and otherwise passes the unions on and chooses the method: a call of `nominal` 6859 can be one specialization). The size and the time are what the splitting cost.
#
# The compile time is that of the program after a first one (that makes the compiler itself compile), so it is the time of the program and what it calls that nothing has compiled before.

using StaticRuntime
using Printf

opaque(x::Integer) = x + oftype(x, time_ns() >> 63)

## abstract types that are listed
abstract type Shape end
struct Circle <: Shape; r::Float64; end
struct Square <: Shape; s::Float64; end
struct Rect <: Shape; w::Float64; h::Float64; end
struct Tri <: Shape; b::Float64; h::Float64; end
struct Ellipse <: Shape; a::Float64; b::Float64; end
area(c::Circle) = 3.0 * c.r^2
area(s::Square) = s.s^2
area(r::Rect) = r.w * r.h
area(t::Tri) = t.b * t.h / 2
area(e::Ellipse) = 3.0 * e.a * e.b
shapes(n) = Shape[(Circle(1.0 + n), Square(2.0), Rect(2.0, 3.0), Tri(2.0, 4.0), Ellipse(1.0, 2.0))...]

# two arguments, abstract
abstract type Animal end
struct A1 <: Animal; x::Int; end
struct A2 <: Animal; x::Int; end
struct A3 <: Animal; x::Int; end
struct A4 <: Animal; x::Int; end
struct A5 <: Animal; x::Int; end
struct A6 <: Animal; x::Int; end
struct A7 <: Animal; x::Int; end
struct A8 <: Animal; x::Int; end
meet(a::Animal, b::Animal) = a.x + b.x
meet(a::A1, b::A2) = 100 + a.x * b.x
meet(a::A3, b::Animal) = 10 + a.x
animals(n) = Animal[A1(n), A2(2), A3(3), A4(4), A5(5), A6(6), A7(7), A8(8)]

meet3(a::Animal, b::Animal, c::Animal) = a.x + b.x + c.x
meet3(a::A1, b::A2, c::Animal) = 100 + a.x * b.x + c.x
meet4(a::Animal, b::Animal, c::Animal, d::Animal) = a.x + b.x + c.x + d.x
meet4(a::A1, b::A2, c::Animal, d::Animal) = 100 + a.x * b.x + c.x + d.x

struct T3; a::Float32; b::Float32; c::Int32; end

# a constructor that converts its arguments to the types of its fields (what `SSAO(radius, bias, blur)` of Makie does): the arguments come from a Dict of Any
struct Obs{T}; v::T; end
Base.convert(::Type{Obs{T}}, x::Obs{T}) where {T} = x
Base.convert(::Type{Obs{T}}, x) where {T} = Obs{T}(convert(T, x))
struct S3o; a::Obs{Float32}; b::Obs{Float32}; c::Obs{Int32}; end
function make_s3o(; radius = nothing, bias = nothing, blur = nothing)
    d = Dict{Symbol,Any}(:radius => 0.5f0, :bias => 0.025f0, :blur => Int32(2))
    r = isnothing(radius) ? d[:radius] : radius
    b = isnothing(bias) ? d[:bias] : bias
    c = isnothing(blur) ? d[:blur] : blur
    return S3o(r, b, c)
end

struct Box1; v::Any; end
describe(x::Int) = x + 1
describe(x::Float64) = round(Int, x * 2)
describe(x::String) = length(x)
describe(x::Symbol) = 7
describe(x::Char) = Int(x)

function return_union(i::Int)
    i % 3 == 0 && return i
    i % 3 == 1 && return float(i)
    return string(i)
end
use_union(x::Int) = x
use_union(x::Float64) = round(Int, x)
use_union(x::String) = length(x)

const PROGRAMS = Dict{String,Function}(
    "listed_shapes"    => () -> (s = 0.0; for sh in shapes(opaque(1)); s += area(sh); end; round(Int, s)),
    "two_args_listed"  => () -> (v = animals(opaque(1)); s = 0; for a in v, b in v; s += meet(a, b); end; s),
    "three_args_listed" => () -> (v = animals(opaque(1)); s = 0; for a in v, b in v, c in v; s += meet3(a, b, c); end; s),
    "four_args_listed" => () -> (v = animals(opaque(1)); s = 0; for a in v, b in v, c in v, d in v[1:2]; s += meet4(a, b, c, d); end; s),
    "any_ctor3"        => () -> (v = Any[opaque(1), 2.5, 3]; t = T3(v[1], v[2], v[3]); round(Int, t.a + t.b + t.c)),
    "any_ctor_convert" => () -> (t = make_s3o(; blur = opaque(3)); round(Int, 100 * t.a.v + 100 * t.b.v + t.c.v)),
    "any_print"        => () -> (v = Any[opaque(1), "a", 2.5, :s, 'c']; for x in v; println(x); end; length(v)),
    "any_arith"        => () -> (v = Any[opaque(1), 2.5, 3]; s = 0; for x in v; s += x; end; round(Int, s)),
    "any_two_args"     => () -> (v = Any[opaque(1), 2.5, 3, 4.0f0]; s = 0.0; for x in v, y in v; s += x * y; end; round(Int, s)),
    "any_field"        => () -> (b = Box1(opaque(5)); describe(b.v) + describe(Box1("abc").v) + describe(Box1(2.5).v)),
    "vector_any_dicts" => () -> (d = Dict{String,Any}("a" => opaque(1), "b" => "xyz", "c" => 2.5); s = 0; for (k, v) in d; s += describe(v); end; s),
    "sort_any"         => () -> (v = Any[opaque(3), 1, 2.5, 0]; sort!(v); round(Int, sum(v))),
    "show_mixed"       => () -> (println(Any[opaque(1), "a", (2, 3.5), [1, 2], :x]); 1),
    "closures_vector"  => () -> (fs = Function[x -> x + 1, x -> 2x, sin]; s = 0.0; for f in fs; s += f(opaque(1) * 1.0); end; round(Int, 10 * s)),
    "union_return"     => () -> (s = 0; for i in 1:opaque(6); s += use_union(return_union(i)); end; s),
    "numeric_baseline" => () -> (s = 0.0; for i in 1:opaque(1_000_000); s += sin(i * 0.001); end; round(Int, s)),
)
const ORDER = ["listed_shapes", "two_args_listed", "three_args_listed", "four_args_listed", "any_ctor3", "any_ctor_convert", "any_print", "any_arith", "any_two_args", "any_field", "vector_any_dicts", "sort_any", "show_mixed", "closures_vector", "union_return", "numeric_baseline"]

# one program: compile it (after a first program, so that the compiler is compiled), run it, and print the measurements as `key=value`
function run_one(name)
    f = PROGRAMS[name]
    warm = StaticRuntime.make_main(() -> 1)
    Base.invokelatest(compile_executable, warm, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(warm)))
    main = StaticRuntime.make_main(f)
    StaticRuntime.DISPATCH_STATS_ON[] = true
    empty!(StaticRuntime.DISPATCH_STATS)
    local exe
    t = @elapsed(exe = Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main))))
    stats = collect(values(StaticRuntime.DISPATCH_STATS))
    run_time = minimum(@elapsed(run(pipeline(ignorestatus(`$exe`); stdout = devnull, stderr = devnull))) for _ in 1:5)
    # (the output is what Julia's is: a program that is smaller and faster and wrong is not better)
    out = read(pipeline(ignorestatus(`$exe`); stderr = devnull), String)
    expected = first(StaticRuntime.expected_output(f))
    correct = out == expected
    println("name=", name, "\tcompile=", round(t; digits = 2), "\tsize=", filesize(exe), "\trun=", round(run_time * 1000; digits = 2),
            "\tsplits=", length(stats), "\tcases=", sum(s -> s.cases, stats; init = 0), "\tmaxcases=", maximum(s -> s.cases, stats; init = 0),
            "\tregistered=", count(s -> s.registered, stats), "\tcorrect=", correct)
end

parse_line(line) = Dict(split(kv, "=") |> collect |> x -> (x[1], x[2]) for kv in split(line, '\t'))

function table(results)
    @printf("%-18s %9s %10s %9s %7s %7s %8s %6s %8s\n", "program", "compile s", "size B", "run ms", "splits", "nominal", "maxnom.", "reg.", "correct")
    for r in results
        @printf("%-18s %9s %10s %9s %7s %7s %8s %6s %8s\n", r["name"], r["compile"], r["size"], r["run"], r["splits"], r["cases"], r["maxcases"], r["registered"], get(r, "correct", "?"))
    end
end

function main_cli(args)
    cmd = isempty(args) ? "list" : args[1]
    if cmd == "list"
        foreach(println, ORDER)
    elseif cmd == "run"
        run_one(args[2])
    elseif cmd == "slots"       # what the slots of an abstract type hold, in the code of the program (src/inference/slots.jl)
        main = StaticRuntime.make_main(PROGRAMS[args[2]])
        ENV["STATIC_RUNTIME_SLOTS"] = "observe"
        empty!(StaticRuntime.SEEN_SLOTS)
        Base.invokelatest(compile_executable, main, (Int, Ptr{Ptr{UInt8}}), mktempdir(), string(nameof(main)))
        StaticRuntime.slots_report()
    elseif cmd == "all"
        script = @__FILE__
        results = Dict{String,String}[]
        lines = String[]
        for name in ORDER
            out = read(ignorestatus(`$(Base.julia_cmd()) --project=$(dirname(dirname(script))) $script run $name`), String)
            found = filter(l -> startswith(l, "name="), split(out, '\n'))
            isempty(found) && (println("no result for ", name); println(out); continue)
            line = String(last(found))
            push!(lines, line)
            push!(results, parse_line(line))
        end
        table(results)
        length(args) >= 2 && write(args[2], join(lines, '\n') * "\n")
    elseif cmd == "compare"
        base = Dict(r["name"] => r for r in parse_line.(filter(!isempty, readlines(args[2]))))
        new = Dict(r["name"] => r for r in parse_line.(filter(!isempty, readlines(args[3]))))
        @printf("%-18s %12s %12s %12s\n", "program", "compile", "size", "run")
        for name in ORDER
            (haskey(base, name) && haskey(new, name)) || continue
            ratio(k) = parse(Float64, new[name][k]) / max(parse(Float64, base[name][k]), 1e-9)
            @printf("%-18s %11.2fx %11.2fx %11.2fx\n", name, ratio("compile"), ratio("size"), ratio("run"))
        end
    else
        error("unknown command $cmd")
    end
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    main_cli(ARGS)
end
