# Calls on types that the program makes when it runs: `getfield` by a name that is known then, `<:` and `isa` with types that are only known then, and what a call that no method fits
# says. The answers for the types of the binary are made when compiling, as tables.

# A call that has no method to run (`Core.throw_methoderror(f, args...)`: what union splitting leaves when the types that were
# split on were all of them) aborts the program, and does not look at its arguments. The function and the types in them are
# not needed, then: where the arguments are put (a frame on the stack), the addresses of objects are replaced by null.
function null_methoderror_arguments!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "jl_f_throw_methoderror") || return false
    changed = false
    ptrT = LLVM.PointerType()
    for use in collect(LLVM.uses(fns["jl_f_throw_methoderror"]))
        call = LLVM.user(use)
        call isa LLVM.CallInst || continue
        frame = LLVM.operands(call)[2]
        name = nothing # of the function that had no method, which is the first of the arguments
        todo = Any[frame]
        while !isempty(todo)
            v = pop!(todo)
            for u in LLVM.uses(v)
                user = LLVM.user(u)
                if user isa LLVM.StoreInst
                    LLVM.operands(user)[2] == v || continue # (it is the pointer that is stored to)
                    value = LLVM.operands(user)[1]
                    if value isa LLVM.ConstantExpr && isinttoptr(value)
                        addr = constant_address(value)
                        name === nothing && addr !== nothing && (name = function_name_at(UInt(addr)))
                        LLVM.operands(user)[1] = LLVM.null(ptrT)
                        changed = true
                    end
                elseif user isa LLVM.GetElementPtrInst
                    push!(todo, user)
                end
            end
        end
        # say which call it was: where the types that were split on were the ones that are registered, it is what an object of
        # another type reaches (see `dispatch.jl`)
        what = name === nothing ? "a call" : "a call of `$name`"
        msg = "MethodError: no method matches the types of the arguments of $what, which can be of a type that was not known when compiling (see `add_dispatch_candidates!`)"
        @dispose builder = LLVM.IRBuilder() begin
            LLVM.position!(builder, LLVM.before(call))
            abort_message!(builder, mod, msg)
        end
        changed = true
    end
    return changed
end

# The name of the function that is the object at `addr` (a function is an object of a type of its own, without contents, that may not be
# aligned as the others are), or `nothing`
function function_name_at(addr::UInt)
    object_type(UInt(0x10000)) # (which sets what the tag of a type is)
    word = safe_load(addr - 8)
    word === nothing && return nothing
    tag = word & ~UInt(15)
    tag < (64 << 4) && return nothing
    typetag = safe_load(tag - 8)
    (typetag === nothing || typetag & ~UInt(15) != DATATYPE_TAG[]) && return nothing
    T = unsafe_pointer_to_objref(Ptr{Cvoid}(tag))
    T isa DataType && Base.issingletontype(T) && T <: Function || return nothing
    return string(nameof(T.instance))
end

# `getfield(x, name)` with a name that is only known at run time (`getproperty(::QRPivoted, ::Symbol)` is, when it is not inlined) is
# `ijl_field_index(T, name, 0)`, the number of the field of the type `T` of that name, or -1. `T` is a constant, so the names
# of its fields are, and the answer is a comparison with each of them (as the symbols of the same name are the same object).
#
# `getfield(x, name)` itself with a name that is only known at run time, of fields of different types, is `jl_f_getfield` in Julia, whose result has a type that the program does not know:
# for a struct the compiler makes it a comparison with each name (`expand_dynamic_getfield!`, `struct_field`). OPEN: it is not done for the fields of a type object (`getproperty(T, name)`),
# which is what fails for `MvNormal` in `test/packages/distributions.jl` under `--code-coverage` (that disables the inlining and the folding that avoid it).
function define_field_index!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "ijl_field_index") && LLVM.isdeclaration(fns["ijl_field_index"]) || return false
    changed = false
    i32 = LLVM.Int32Type()
    i64 = LLVM.Int64Type()
    ptrT = LLVM.PointerType()
    for use in collect(LLVM.uses(fns["ijl_field_index"]))
        call = LLVM.user(use)
        call isa LLVM.CallInst || continue
        ops = LLVM.operands(call)
        (ops[3] isa LLVM.ConstantInt && convert(Int, ops[3]) == 0) || continue # (one that throws is not done)
        addr = constant_object_address(ops[1])
        addr === nothing && continue
        object_type(addr) === DataType || continue
        T = unsafe_pointer_to_objref(Ptr{Cvoid}(addr))::DataType
        LLVM.@dispose builder = LLVM.IRBuilder() begin
            LLVM.position!(builder, LLVM.before(call))
            result = LLVM.ConstantInt(i32, -1)
            for (i, name) in reverse(collect(enumerate(fieldnames(T))))
                sym = LLVM.const_inttoptr(LLVM.ConstantInt(i64, UInt64(ccall(:jl_value_ptr, UInt, (Any,), name))), ptrT)
                same = LLVM.icmp!(builder, LLVM.API.LLVMIntEQ, ops[2], sym)
                result = LLVM.select!(builder, same, LLVM.ConstantInt(i32, i - 1), result)
            end
            LLVM.replace_uses!(call, result)
        end
        LLVM.erase!(call)
        changed = true
    end
    return changed
end

# `x isa T` for an `x` that is only known at run time, and a type `T` that is not concrete (`Number`, `Union{A,B}`,
# `AbstractVector{Int}`), is `ijl_subtype(typeof(x), T)`: libjulia's subtyping, which is a large and complicated part
# of it. The types that `T` is in the code are constants, though, and the types that the objects of the program can have are
# those in the binary (the tags of the objects are those): so the answers can be had when compiling, from Julia's
# `<:`, for each of the types in the binary and each type that is asked about. Written out as `ijl_subtype`: a
# comparison of the second argument with each of those types, and of the first with the types that are subtypes of it.
# A call with a type that was not one of those exits with a message, as does one of a type that is not in the binary
# (which has no objects).

# the addresses of the types that `ijl_subtype` is called with, or `nothing` if the function is used in any other way
function subtype_queries(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "ijl_subtype") && LLVM.isdeclaration(fns["ijl_subtype"]) || return UInt[]
    addrs = Set{UInt}()
    for use in LLVM.uses(fns["ijl_subtype"])
        inst = LLVM.user(use)
        inst isa LLVM.CallInst || return nothing
        addr = constant_object_address(LLVM.operands(inst)[2])
        addr === nothing && return nothing
        push!(addrs, addr)
    end
    return sort!(collect(addrs))
end

function define_subtype!(e, queries::Vector{UInt}) # (e::ObjectEmbedder, which is defined below)
    mod = e.mod
    haskey(LLVM.functions(mod), "ijl_subtype") && LLVM.isdeclaration(LLVM.functions(mod)["ijl_subtype"]) || return
    fn = LLVM.functions(mod)["ijl_subtype"]
    # the concrete types that are in the binary
    concrete = Tuple{UInt,DataType}[]
    for (addr, g) in e.globals
        g === nothing && continue
        object_type(addr) === DataType || continue
        T = unsafe_pointer_to_objref(Ptr{Cvoid}(addr))
        T isa DataType && isconcretetype(T) && push!(concrete, (addr, T))
    end
    sort!(concrete; by = first)
    # (a type that was asked about but is not in the binary is left for the exit at the end)
    asked = [(addr, unsafe_pointer_to_objref(Ptr{Cvoid}(addr))) for addr in queries if get(e.globals, addr, nothing) !== nothing]
    LLVM.linkage!(fn, LLVM.API.LLVMLinkOnceODRLinkage)
    a, b = LLVM.parameters(fn)
    @dispose builder = LLVM.IRBuilder() begin
        entry = LLVM.BasicBlock(fn, "entry")
        checks = [LLVM.BasicBlock(fn, "check$i") for i in eachindex(asked)]
        unknown = LLVM.BasicBlock(fn, "unknown")
        LLVM.position!(builder, LLVM.at_end(entry))
        LLVM.br!(builder, isempty(checks) ? unknown : first(checks))
        for (i, (addr, T)) in enumerate(asked)
            hit = LLVM.BasicBlock(fn, "hit$i")
            LLVM.position!(builder, LLVM.at_end(checks[i]))
            is_it = LLVM.icmp!(builder, LLVM.API.LLVMIntEQ, b, embed_ref!(e, addr))
            LLVM.br!(builder, is_it, hit, i < length(checks) ? checks[i + 1] : unknown)
            LLVM.position!(builder, LLVM.at_end(hit))
            subtypes = [taddr for (taddr, S) in concrete if S <: T]
            result = nothing
            for taddr in subtypes
                same = LLVM.icmp!(builder, LLVM.API.LLVMIntEQ, a, embed_ref!(e, taddr))
                result = result === nothing ? same : LLVM.or!(builder, result, same)
            end
            LLVM.ret!(builder, result === nothing ? LLVM.ConstantInt(Int32(0)) :
                                                   LLVM.zext!(builder, result, LLVM.Int32Type()))
        end
        LLVM.position!(builder, LLVM.at_end(unknown))
        abort_message!(builder, mod, "isa with a type that is not known when compiling is not supported in standalone binaries")
        LLVM.unreachable!(builder)
    end
    return
end

# `a <: b` for two types that are only known when the program runs (a `Vector{DataType}` of the types of some objects, compared
# with a type): `jl_f_issubtype`, the builtin, which is `ijl_subtype` with its arguments in an array and its result boxed; and
# `x isa T` for a type `T` that is only known then: the same with the type of `x`, which is its tag
function define_subtype_builtins!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    wanted(name) = haskey(fns, name) && LLVM.isdeclaration(fns[name]) && !isempty(LLVM.uses(fns[name]))
    (wanted("jl_f_issubtype") || wanted("jl_f_isa")) || return false
    ptrT, i64 = LLVM.PointerType(), LLVM.Int64Type()
    sub_t = LLVM.FunctionType(LLVM.Int32Type(), [ptrT, ptrT])
    sub = declare!(mod, "ijl_subtype", sub_t)
    globals = LLVM.globals(mod)
    jl_true = haskey(globals, "jl_true") ? globals["jl_true"] : LLVM.GlobalVariable(mod, ptrT, "jl_true")
    jl_false = haskey(globals, "jl_false") ? globals["jl_false"] : LLVM.GlobalVariable(mod, ptrT, "jl_false")
    small = nothing
    if wanted("jl_f_isa")
        small = haskey(globals, "jl_small_typeof") ? globals["jl_small_typeof"] :
                LLVM.GlobalVariable(mod, LLVM.ArrayType(ptrT, (64 << 4) ÷ sizeof(Ptr)), "jl_small_typeof")
    end
    for name in ("jl_f_issubtype", "jl_f_isa")
        wanted(name) || continue
        fn = LLVM.functions(mod)[name]
        LLVM.linkage!(fn, LLVM.API.LLVMLinkOnceODRLinkage)
        _, args, _ = LLVM.parameters(fn)
        @dispose builder = LLVM.IRBuilder() begin
            LLVM.position!(builder, LLVM.at_end(LLVM.BasicBlock(fn, "entry")))
            first_arg = LLVM.load!(builder, ptrT, args)
            second = LLVM.load!(builder, ptrT, LLVM.gep!(builder, ptrT, args, [LLVM.ConstantInt(Int64(1))]))
            a = first_arg
            if name == "jl_f_isa"
                # the type of the object: its tag, or the type of the small number that stands for one
                tag_slot = LLVM.gep!(builder, LLVM.Int8Type(), first_arg, [LLVM.ConstantInt(Int64(-8))])
                tag = LLVM.and!(builder, LLVM.load!(builder, i64, tag_slot), LLVM.ConstantInt(Int64(-16)))
                is_small = LLVM.icmp!(builder, LLVM.API.LLVMIntULT, tag, LLVM.ConstantInt(Int64(64 << 4)))
                entry_ptr = LLVM.gep!(builder, LLVM.ArrayType(ptrT, (64 << 4) ÷ sizeof(Ptr)), small,
                                      [LLVM.ConstantInt(Int64(0)), LLVM.lshr!(builder, tag, LLVM.ConstantInt(Int64(3)))])
                # (a load that is not made for a tag that is not small: the index of a big tag is out of the table)
                index_ok = LLVM.select!(builder, is_small, entry_ptr, LLVM.gep!(builder, LLVM.ArrayType(ptrT, (64 << 4) ÷ sizeof(Ptr)), small, [LLVM.ConstantInt(Int64(0)), LLVM.ConstantInt(Int64(0))]))
                small_type = LLVM.load!(builder, ptrT, index_ok)
                a = LLVM.select!(builder, is_small, small_type, LLVM.inttoptr!(builder, tag, ptrT))
            end
            r = LLVM.call!(builder, sub_t, sub, [a, second])
            yes = LLVM.icmp!(builder, LLVM.API.LLVMIntNE, r, LLVM.ConstantInt(Int32(0)))
            LLVM.ret!(builder, LLVM.select!(builder, yes, LLVM.load!(builder, ptrT, jl_true), LLVM.load!(builder, ptrT, jl_false)))
        end
    end
    return true
end

# `ijl_subtype(a, b)` for any two of the types that are in the binary: a table of the answers, which Julia's `<:` gave when
# compiling, for each pair (a bit for each, row `b`, column `a`), and a search of the table of types for each of the arguments. (A type
# that is not in the binary can't be the type of an object that the program has, or a type that it can name, so it is not asked about.)
# `define_subtype!` is shorter for what is asked about with types that are constants, and is used if all of the calls are like that.
function define_subtype_table!(e)
    mod = e.mod
    haskey(LLVM.functions(mod), "ijl_subtype") && LLVM.isdeclaration(LLVM.functions(mod)["ijl_subtype"]) || return
    fn = LLVM.functions(mod)["ijl_subtype"]
    found = Tuple{UInt,Any}[]
    for (addr, g) in e.globals
        g === nothing && continue
        K = object_type(addr)
        (K === DataType || K === Union || K === UnionAll || K === Core.TypeofBottom) || continue
        push!(found, (addr, unsafe_pointer_to_objref(Ptr{Cvoid}(addr))))
    end
    sort!(found; by = first)
    n = length(found)
    rowbytes = (n + 7) >> 3
    bits = zeros(UInt8, n * rowbytes)
    for (ib, (_, B)) in enumerate(found), (ia, (_, A)) in enumerate(found)
        A <: B || continue
        k = (ib - 1) * n + (ia - 1)
        bits[(k >> 3) + 1] |= UInt8(1) << (k & 7)
    end
    ptrT, i64, i32 = LLVM.PointerType(), LLVM.Int64Type(), LLVM.Int32Type()
    types_t = LLVM.ArrayType(ptrT, n)
    types_g = LLVM.GlobalVariable(mod, types_t, "static_subtype_types")
    LLVM.initializer!(types_g, LLVM.ConstantArray(ptrT, LLVM.Constant[embed_ref!(e, addr) for (addr, _) in found]))
    LLVM.constant!(types_g, true); LLVM.linkage!(types_g, LLVM.API.LLVMPrivateLinkage)
    bits_g = LLVM.GlobalVariable(mod, LLVM.ArrayType(LLVM.Int8Type(), length(bits)), "static_subtype_bits")
    LLVM.initializer!(bits_g, LLVM.ConstantDataArray(LLVM.Int8Type(), bits))
    LLVM.constant!(bits_g, true); LLVM.linkage!(bits_g, LLVM.API.LLVMPrivateLinkage)
    LLVM.linkage!(fn, LLVM.API.LLVMLinkOnceODRLinkage)
    a, b = LLVM.parameters(fn)
    N = LLVM.ConstantInt(Int64(n))
    @dispose builder = LLVM.IRBuilder() begin
        entry = LLVM.BasicBlock(fn, "entry")
        loopa, bodya, nexta = (LLVM.BasicBlock(fn, s) for s in ("loopa", "bodya", "nexta"))
        loopb, bodyb, nextb = (LLVM.BasicBlock(fn, s) for s in ("loopb", "bodyb", "nextb"))
        lookup, unknown = LLVM.BasicBlock(fn, "lookup"), LLVM.BasicBlock(fn, "unknown")
        LLVM.position!(builder, LLVM.at_end(entry)); LLVM.br!(builder, loopa)
        # the index of `a`
        LLVM.position!(builder, LLVM.at_end(loopa))
        ia = LLVM.phi!(builder, i64, "ia")
        LLVM.br!(builder, LLVM.icmp!(builder, LLVM.API.LLVMIntEQ, ia, N), unknown, bodya)
        LLVM.position!(builder, LLVM.at_end(bodya))
        va = LLVM.load!(builder, ptrT, LLVM.gep!(builder, types_t, types_g, [LLVM.ConstantInt(Int64(0)), ia]))
        LLVM.br!(builder, LLVM.icmp!(builder, LLVM.API.LLVMIntEQ, va, a), loopb, nexta)
        LLVM.position!(builder, LLVM.at_end(nexta))
        ia_next = LLVM.add!(builder, ia, LLVM.ConstantInt(Int64(1)))
        LLVM.br!(builder, loopa)
        append!(LLVM.incoming(ia), [(LLVM.ConstantInt(Int64(0)), entry), (ia_next, nexta)])
        # the index of `b`
        LLVM.position!(builder, LLVM.at_end(loopb))
        ib = LLVM.phi!(builder, i64, "ib")
        LLVM.br!(builder, LLVM.icmp!(builder, LLVM.API.LLVMIntEQ, ib, N), unknown, bodyb)
        LLVM.position!(builder, LLVM.at_end(bodyb))
        vb = LLVM.load!(builder, ptrT, LLVM.gep!(builder, types_t, types_g, [LLVM.ConstantInt(Int64(0)), ib]))
        LLVM.br!(builder, LLVM.icmp!(builder, LLVM.API.LLVMIntEQ, vb, b), lookup, nextb)
        LLVM.position!(builder, LLVM.at_end(nextb))
        ib_next = LLVM.add!(builder, ib, LLVM.ConstantInt(Int64(1)))
        LLVM.br!(builder, loopb)
        append!(LLVM.incoming(ib), [(LLVM.ConstantInt(Int64(0)), bodya), (ib_next, nextb)])
        # the bit of row `ib`, column `ia`
        LLVM.position!(builder, LLVM.at_end(lookup))
        k = LLVM.add!(builder, LLVM.mul!(builder, ib, N), ia)
        byte = LLVM.load!(builder, LLVM.Int8Type(), LLVM.gep!(builder, LLVM.ArrayType(LLVM.Int8Type(), length(bits)), bits_g,
                                                           [LLVM.ConstantInt(Int64(0)), LLVM.lshr!(builder, k, LLVM.ConstantInt(Int64(3)))]))
        shift = LLVM.trunc!(builder, LLVM.and!(builder, k, LLVM.ConstantInt(Int64(7))), LLVM.Int8Type())
        bit = LLVM.and!(builder, LLVM.lshr!(builder, byte, shift), LLVM.ConstantInt(Int8(1)))
        LLVM.ret!(builder, LLVM.zext!(builder, bit, i32))
        LLVM.position!(builder, LLVM.at_end(unknown))
        abort_message!(builder, mod, "<: with a type that is not in the binary is not supported in standalone binaries")
        LLVM.unreachable!(builder)
    end
    return
end
