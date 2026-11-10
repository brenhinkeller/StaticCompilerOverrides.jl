# Constants that are referenced by address, which `Runtime.embed_constants!` copies into the binary.
#
# A constant can point into the middle of an object (e.g. at the data of a string: LLVM folds the
# offset into the address). Objects are recognized by their type tag, which is the word before
# them, and for a pointer into a string, that word is the string's length: which looks like a valid
# tag for some lengths. Check that, for every length, the right object is found.

@testset "Embedding constants: interior pointers" begin
    SC = StaticCompilerOverrides.StaticCompiler
    Runtime = StaticCompilerOverrides.Runtime

    # a module with a function that loads a byte from `addr`; returns the (name of the global,
    # offset into it) that the address was replaced by, or `nothing`
    function embedded(addr::UInt)
        SC.GPUCompiler.JuliaContext() do ctx
            mod = LLVM.Module("embedding_test")
            try
                fn = LLVM.Function(mod, "f", LLVM.FunctionType(LLVM.Int8Type()))
                @dispose builder = LLVM.IRBuilder() begin
                    LLVM.position!(builder, LLVM.at_end(LLVM.BasicBlock(fn, "entry")))
                    ptr = LLVM.const_inttoptr(LLVM.ConstantInt(Int64(addr)), LLVM.PointerType())
                    LLVM.ret!(builder, LLVM.load!(builder, LLVM.Int8Type(), ptr))
                end
                Runtime.embed_constants!(mod)
                load = first(LLVM.instructions(first(LLVM.blocks(fn))))
                op = LLVM.operands(load)[1]
                text = string(op)
                occursin("inttoptr", text) && return nothing
                name = match(r"@(static_object_[0-9a-f]+)", text)
                # the object itself, or a constant offset into it (`getelementptr (i8, ptr @object, i64 offset)`)
                offset = if op isa LLVM.ConstantExpr && (m = match(r"i64 (\d+)\)$", text)) !== nothing
                    parse(Int, m.captures[1])
                else
                    0 # (not possible now: there is always the header)
                end
                return name === nothing ? nothing : (name.captures[1], offset)
            finally
                LLVM.dispose(mod)
            end
        end
    end

    strings = String[] # keep them alive: we look at their addresses
    failures = String[]
    for len in 0:1100
        s = String(rand('a':'z', len))
        push!(strings, s)
        base = UInt(pointer_from_objref(s))
        # the object itself, the length word, and (when there is room) the first data words
        for offset in (0, 8, 16, 24)
            offset == 0 || len >= offset - 8 + 1 || continue
            got = embedded(base + offset)
            expected = ("static_object_" * string(base, base = 16), StaticCompilerOverrides.Runtime.EMBED_HEADER + offset)
            got == expected || push!(failures, "length $len, offset $offset: got $got, expected $expected")
        end
    end
    # the same for binary data, which is more likely to contain words that look like type tags
    memories = Memory{UInt8}[]
    for len in 1:600
        m = Memory{UInt8}(undef, len)
        m .= rand(UInt8, len)
        push!(memories, m)
        base = UInt(pointer_from_objref(m))
        # the object, and the first bytes of its data, which follow the header of 16 bytes
        for offset in (0, 16, 24)
            offset == 0 || len > offset - 16 || continue
            got = embedded(base + offset)
            expected = ("static_object_" * string(base, base = 16), StaticCompilerOverrides.Runtime.EMBED_HEADER + offset)
            got == expected || push!(failures, "Memory{UInt8} of length $len, offset $offset: got $got, expected $expected")
        end
    end
    @test isempty(failures)
    isempty(failures) || println(join(first(failures, 10), "\n"), "\n... ", length(failures), " in total")
end

# Constants are shared by all the functions of a library: they are compiled separately (and then
# linked), and a mutable object that they all refer to has to remain one object
@testset "Embedding constants: shared state across functions" begin
    @eval const SHARED_COUNTER = Ref(0)
    @eval shared_inc() = (SHARED_COUNTER[] += 1; Int(SHARED_COUNTER[]))
    @eval shared_get() = Int(SHARED_COUNTER[])
    lib = Base.invokelatest(compile_shlib, [(shared_inc, ()), (shared_get, ())], mktempdir())
    handle = dlopen(lib)
    try
        inc() = ccall(dlsym(handle, :shared_inc), Int, ())
        get() = ccall(dlsym(handle, :shared_get), Int, ())
        @test get() == 0
        @test inc() == 1
        @test inc() == 2
        @test get() == 2 # the same counter
    finally
        dlclose(handle)
    end
end

# The type objects that a program has are there to be told apart (the tag of an object, the type of an `isa`), and to be named: the
# supertypes, the wrappers and the names of the fields of them are not copied, which is most of the objects of a small program
@testset "Embedding constants: the types are not copied with their supertypes" begin
    Runtime = StaticCompilerOverrides.Runtime
    embedded = Any[]
    main = StaticCompilerOverrides.make_main(() -> (println(42); 1))
    mod = Base.invokelatest(static_llvm_module, main, Tuple{Int,Ptr{Ptr{UInt8}}}; llvm_postprocess = mod -> begin
        Runtime.link_runtime!(mod; strict = true, allow = (), gc = false)
        for g in LLVM.globals(mod)
            m = match(r"^static_object_([0-9a-f]+)$", LLVM.name(g))
            m === nothing && continue
            addr = parse(UInt, m.captures[1]; base = 16)
            Runtime.object_type(addr) === DataType && push!(embedded, unsafe_pointer_to_objref(Ptr{Cvoid}(addr)))
        end
    end)
    LLVM.dispose(mod)
    @test !isempty(embedded)
    @test !any(T -> T in (Number, Real, Integer, Signed, Any), embedded)
    # and what a program asks of a type that it has is still there
    named() = (n = 0; for x in Any[1, [1.5], (1, "a"), "s"]; n += length(String(nameof(typeof(x)))) + length(typeof(x).parameters); end; n)
    @test static_result(named) == named()
end

# Found compiling Thermochron.jl: an immutable struct of many fields (a `SphericalHe` is 392 bytes) that is a constant: its fields
# beyond 256 bytes were looked for as objects of their own, and not found
struct ManyFields
    a1::Vector{Int}; a2::Vector{Int}; a3::Vector{Int}; a4::Vector{Int}; a5::Vector{Int}; a6::Vector{Int}; a7::Vector{Int}; a8::Vector{Int}
    b1::Vector{Int}; b2::Vector{Int}; b3::Vector{Int}; b4::Vector{Int}; b5::Vector{Int}; b6::Vector{Int}; b7::Vector{Int}; b8::Vector{Int}
    c1::Vector{Int}; c2::Vector{Int}; c3::Vector{Int}; c4::Vector{Int}; c5::Vector{Int}; c6::Vector{Int}; c7::Vector{Int}; c8::Vector{Int}
    d1::Vector{Int}; d2::Vector{Int}; d3::Vector{Int}; d4::Vector{Int}; d5::Vector{Int}; d6::Vector{Int}; d7::Vector{Int}; d8::Vector{Int}
    e1::Vector{Int}; e2::Vector{Int}; e3::Vector{Int}; e4::Vector{Int}; e5::Vector{Int}; e6::Vector{Int}; e7::Vector{Int}; e8::Vector{Int}
    name::String
end
const MANY = ManyFields((([i] for i in 1:40)..., "many")...)
many_sum(m::ManyFields) = m.a1[1] + m.b8[1] + m.c3[1] + m.d8[1] + m.e1[1] + m.e8[1] + ncodeunits(m.name)
@testset "Large constant structs" begin
    @test sizeof(MANY) > 256
    @static_test many_sum(MANY)
end
