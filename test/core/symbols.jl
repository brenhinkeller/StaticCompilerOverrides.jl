# Symbols: constants in `Dict`s and `Set`s, `string` and `Symbol` of a `String` that the program makes, and `Dict`s of types.

sy_p(x) = (println(x); 0)
sy_word() = Base.inferencebarrier("hello")::String
sy_num() = Base.inferencebarrier(7)::Int
sy_sym() = Base.inferencebarrier(:foo)::Symbol

const SY_DICT = Dict(:a => 1, :b => 2, :abc => 3, :end => 4)
const SY_SET = Set([:x, :y, :abc])
const SY_TYPES = Dict(Int => 1, Float64 => 2, Number => 3, Vector{Int} => 4, Tuple{Int,String} => 5)
const SY_LIST = [:red, :green, :blue]

sy_struct_a() = @opaque((s = Pair(:a, 3); getfield(s, Base.inferencebarrier(:first)::Symbol) === :a))

# the symbols of a binary: in tables made when compiling, and used by a program that makes its own
sy_dict_get() = @opaque(SY_DICT[:b] + get(SY_DICT, :zz, 100) + SY_DICT[:end])
sy_set_in() = @opaque((:x in SY_SET) + 2 * (:q in SY_SET))
sy_dict_runtime() = @opaque((d = Dict{Symbol,Int}(); d[:a] = 1; d[:b] = 2; d[:a] + d[:b] + length(d)))
sy_dict_mixed() = @opaque((d = Dict(:a => 1, :b => 2); d[Symbol("a")] + d[Symbol(sy_word()[1:1] == "h" ? "b" : "a")]))
sy_symbol_list() = (n = 0; for s in SY_LIST; n += length(string(s)); end; n)

# a name made by the program is the symbol that the binary has (`===`, a key of a table that was made when compiling)
sy_made_is_embedded() = (Symbol(sy_word()[1:2], "ello") === :hello) + 2 * (Symbol("ab" * string(Base.inferencebarrier('c'))) === :abc)
sy_made_in_const_dict() = SY_DICT[Symbol("ab" * string(Base.inferencebarrier('c')))] + SY_DICT[Symbol(Base.inferencebarrier("b"))]
sy_made_in_const_set() = Symbol(Base.inferencebarrier("a") * "bc") in SY_SET
sy_made_twice() = (Symbol("new_" * sy_word()) === Symbol("new_" * sy_word())) + 2 * (Symbol("new_a") !== Symbol("new_b")) + 4 * (Symbol("zzz" * sy_word()) !== :zzz)
sy_made_hash() = (hash(Symbol("new_" * sy_word())) == hash(Symbol("new_" * sy_word()))) + 2 * (hash(Symbol(Base.inferencebarrier("abc"))) == hash(:abc))
sy_made_in_dict() = (d = Dict{Symbol,Int}(); for i in 1:50; d[Symbol("key", i)] = i; end; s = 0; for i in 1:50; s += d[Symbol("key", i)]; end; s + length(d))
sy_many() = (s = 0; for i in 1:2000; s += Symbol("sym_", i) === Symbol("sym_", i); end; s)
sy_roundtrip() = (n = 0; for s in (:red, :green, :blue); n += (Symbol(string(s)) === s) + (Symbol(String(s)) === s); end; n)

# strings from symbols, and symbols from strings
sy_string() = sy_p(string(sy_sym()))
sy_string_made() = sy_p(string(Symbol("made_" * sy_word())))
sy_symbol_parts() = sy_p(Symbol("x", sy_num(), "_", sy_sym(), 'c', 2.5))
sy_symbol_upper() = sy_p(Symbol(uppercase(string(sy_sym()))))
sy_symbol_bytes() = @opaque(sy_p(Symbol(UInt8[0x61, 0x62, 0x63])))
sy_symbol_sub() = @opaque(sy_p(Symbol(SubString(sy_word(), 2, 4))))
sy_symbol_char() = sy_p(Symbol(Base.inferencebarrier('q')))
sy_symbol_empty() = sy_p(string(Symbol(Base.inferencebarrier(""))))
sy_symbol_unicode() = sy_p(Symbol("α", sy_word()))
sy_interp() = sy_p("value: $(sy_sym()) and $(Symbol(sy_word()))")
sy_sort() = sy_p(string(sort([Symbol("b", sy_num()), :a, Symbol("c", sy_num()), :aa])))
sy_startswith() = startswith(string(Symbol("pre", sy_word())), "pre")
sy_length() = length(string(Symbol("pre", sy_word())))

# getfield, getproperty and `NamedTuple`s with a symbol that is made
sy_getfield() = (s = SyS(3, 4.5); getfield(s, Symbol("a")) + getfield(s, Symbol(Base.inferencebarrier("b"))))
struct SyS; a::Int; b::Float64; end

# `show` of symbols: the ones that are `:name`, and the others as Julia writes them
sy_show_plain() = (show(:abc); println(); show(:end); println(); show(Symbol("a1!")); println(); 0)
sy_show_operators() = (show(:+); println(); show(:(==)); println(); show(:(=)); println(); show(:&&); println(); show(:..); println(); show(:⊕); println(); 0)
sy_show_other() = (show(:α); println(); show(Symbol("a b")); println(); show(Symbol("1a")); println(); show(Symbol("a+b")); println(); show(Symbol("")); println(); 0)
sy_show_made() = (show(Symbol("with space " * sy_word())); println(); show(Symbol(Base.inferencebarrier("9")::String, sy_word())); println(); show(Symbol(sy_word())); println(); 0)
sy_show_container() = (println(Any[:a, Symbol("b c"), :+, 1]); println(Dict(:x => 1, Symbol("y z") => 2)); println((:a, :+)); 0)

# types: `==` of them, `hash`, and `Dict`s and `Set`s of them
sy_types_eq() = @opaque((Int == Int) + 2 * (Int == Float64) + 4 * (Number == Number) + 8 * (Vector{Int} == Vector{Int}) + 16 * (Vector{Int} == Vector{Float64}) + 32 * (Int == Number))
sy_types_eq_runtime() = @opaque((T = Base.inferencebarrier(Int)::DataType; S = Base.inferencebarrier(Float64)::DataType; (T == T) + 2 * (T == S) + 4 * (T === T)))
sy_types_dict_const() = @opaque(SY_TYPES[Float64] + SY_TYPES[Number] + SY_TYPES[Vector{Int}] + SY_TYPES[Tuple{Int,String}] + get(SY_TYPES, Bool, 100))
sy_types_dict_runtime() = @opaque((d = Dict{DataType,Int}(); d[Int] = 1; d[Float64] = 2; d[Number] = 3; d[Int] + d[Float64] + d[Number] + length(d)))
sy_types_dict_lookup() = @opaque((T = Base.inferencebarrier(Float64)::DataType; SY_TYPES[T] + SY_TYPES[Base.inferencebarrier(Vector{Int})::DataType]))
sy_types_set() = @opaque((s = Set{DataType}([Int, Float64, Int]); length(s) + (Int in s) + 2 * (Bool in s)))
sy_types_hash() = (hash(Int) == hash(Int)) + 2 * (hash(Int) != hash(Float64)) + 4 * (hash(Base.inferencebarrier(Int)::DataType) == hash(Int))

const SYMBOL_CASES = [
    sy_struct_a, sy_dict_get, sy_set_in, sy_dict_runtime, sy_dict_mixed, sy_symbol_list,
    sy_made_is_embedded, sy_made_in_const_dict, sy_made_in_const_set, sy_made_twice, sy_made_hash, sy_made_in_dict, sy_many, sy_roundtrip,
    sy_string, sy_string_made, sy_symbol_parts, sy_symbol_upper, sy_symbol_bytes, sy_symbol_sub, sy_symbol_char, sy_symbol_empty, sy_symbol_unicode,
    sy_interp, sy_sort, sy_startswith, sy_length,
    sy_show_plain, sy_show_operators, sy_show_other, sy_show_made, sy_show_container,
    sy_types_eq, sy_types_eq_runtime, sy_types_dict_const, sy_types_dict_runtime, sy_types_dict_lookup, sy_types_set, sy_types_hash,
]

@testset "Symbols and types as keys" begin
    check_cases(SYMBOL_CASES)
end

# A `NamedTuple` with a name that is not known when compiling (`nt[name]`, `nt.name`, `get`): the type of the result is the union of the types of the fields (the table of the scales of UnicodePlots has a function for each)
const SY_NT2 = (a = 1, b = 2, c = 3)
const SY_NT_MIXED = (alpha = 1, beta = 2.5, gamma = "str", up = uppercase, down = lowercase)
sy_nt_name(s) = Symbol(Base.inferencebarrier(s))
@testset "NamedTuples with a name that is made" begin
    check_cases([
        "fields of one type"   => () -> SY_NT2[sy_nt_name("b")] + SY_NT2[sy_nt_name("c")],
        "fields of two types"  => () -> Int(round(10 * (SY_NT_MIXED[sy_nt_name("alpha")] + SY_NT_MIXED[sy_nt_name("beta")]))),
        "a String"             => () -> ncodeunits(SY_NT_MIXED[sy_nt_name("gamma")]),
        "functions"            => () -> ncodeunits(SY_NT_MIXED[sy_nt_name("up")]("abc")) + 10 * Int(SY_NT_MIXED[sy_nt_name("down")]("ABC") == "abc"),
        "getproperty"          => () -> getproperty(SY_NT2, sy_nt_name("c")) * 2,
        "a name that is known"  => () -> SY_NT2.b + SY_NT_MIXED.alpha + SY_NT2[:c],
        "get with a default"   => () -> get(SY_NT2, sy_nt_name("zz"), 100) + get(SY_NT2, sy_nt_name("a"), 100),
        "a name that is not there" => () -> (try; SY_NT2[sy_nt_name("zz")] + 1; catch e; e isa FieldError ? 7 : 8; end),
    ])
end

# `getfield` of a struct with a field named by a symbol that is not known when compiling needs the types of the fields when the program runs (not supported yet)
@testset "Fields of a struct named by a symbol that is made" begin
    @test_broken static_status(sy_getfield)[1] == :ok
end

# The test that a name is a plain identifier, made in the linker and in the program, is the same one
@testset "Plain symbol names" begin
    names = ["a", "abc", "a1", "a!", "_x", "A", "x_y", "1a", "a b", "a+b", "+", "==", "", "α", "a.b", "!a", "end", "a'"]
    for name in names
        @test StaticRuntime.Runtime.plain_symbol_name(codeunits(name)) == StaticRuntime.symbol_is_plain(Symbol(name))
    end
end

# a `Symbol` that is taken from a vector, so that it is not known when compiling (AliasTables, which `sample` uses, makes messages with one)
symbol_name(x::Vector{Symbol}) = x[1]
@testset "Symbols that are not known when compiling" begin
    check_cases([
        "printed and made into strings" => () -> (v = Base.inferencebarrier([:abcd, :ef])::Vector{Symbol}; s = symbol_name(v); ncodeunits(string("x ", s, " y")) + 100 * ncodeunits(sprint(print, s))),
        "printed"                       => () -> (v = Base.inferencebarrier([:abcd])::Vector{Symbol}; print(symbol_name(v)); 0),
    ])
end
