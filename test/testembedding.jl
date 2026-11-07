# Constants that are referenced by address, which `Runtime.embed_constants!` copies into the binary.
#
# A constant can point into the middle of an object (e.g. at the data of a string: LLVM folds the
# offset into the address). Objects are recognized by their type tag, which is the word before
# them, and for a pointer into a string, that word is the string's length: which looks like a valid
# tag for some lengths. Check that, for every length, the right object is found.
using Test
using LLVM: LLVM, @dispose

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
    using Libdl: dlopen, dlsym, dlclose
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
