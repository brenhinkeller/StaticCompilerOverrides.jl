# Finding the constants of a module (`inttoptr` of an address of this process, and the numbers that are the addresses of types), and putting what they refer to in the binary
# (`embed_constants!`): the objects (`embedder.jl`), the types and the tests of the type of an object (`isa`, `typeof`, the `switch`es on tags), and the `Symbol`s of the program.

# all `inttoptr (i64 N to ptr)` constants used by instructions of `mod`, by address
function inttoptr_constants(mod::LLVM.Module)
    consts = Dict{UInt,Vector{LLVM.Value}}()
    seen = Set{Ptr{Cvoid}}() # (constants are shared by all their uses)
    for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb), op in LLVM.operands(inst)
        for node in inttoptr_nodes(op)
            Ptr{Cvoid}(node.ref) in seen && continue
            push!(seen, Ptr{Cvoid}(node.ref))
            addr = constant_address(node)
            (addr === nothing || addr < 0x10000) && continue
            push!(get!(Vector{LLVM.Value}, consts, UInt(addr)), node)
        end
    end
    return consts
end

# The `inttoptr` constants in an operand: it is one, or has them in it, when it is an address that is an offset
# from one (`getelementptr (i8, inttoptr (...), -8)`: the tag of an object is 8 bytes before it). Replacing
# the `inttoptr` itself, and not the expression it is a part of, keeps the arithmetic as it is.
function inttoptr_nodes(op, found = LLVM.ConstantExpr[])
    op isa LLVM.ConstantExpr || return found
    occursin("inttoptr", string(op)) || return found
    if LLVM.API.LLVMGetConstOpcode(op) == LLVM.API.LLVMIntToPtr
        push!(found, op)
    else
        for sub in LLVM.operands(op)
            inttoptr_nodes(sub, found)
        end
    end
    return found
end

# A number in the code is an address of an object of this process only if it is used as one. A constant that is a count or a seed can be the
# address of an object (in a process where the memory that Julia has is at low addresses, as on Linux when the executable is not position
# independent: that of `115938146` was a symbol), and then taking it for one gives a program that quietly computes with another number. So a
# number that is *data* is never taken for an address: an operand of arithmetic (`add`, `shl`, `xor`, ...), what a function returns, and an argument
# in the `...` of a function with a variable number of them (`printf("%ld", n)`); what is compared (`icmp`) or stored, as the type tags are, is not.
const ARITHMETIC_OPCODES = Set([LLVM.API.LLVMAdd, LLVM.API.LLVMSub, LLVM.API.LLVMMul, LLVM.API.LLVMUDiv, LLVM.API.LLVMSDiv, LLVM.API.LLVMURem,
                                LLVM.API.LLVMSRem, LLVM.API.LLVMShl, LLVM.API.LLVMLShr, LLVM.API.LLVMAShr, LLVM.API.LLVMAnd, LLVM.API.LLVMOr, LLVM.API.LLVMXor])

function integer_operand_is_data(inst::LLVM.Instruction, i::Int)
    opcode = LLVM.API.LLVMGetInstructionOpcode(inst)
    (opcode in ARITHMETIC_OPCODES || opcode == LLVM.API.LLVMRet) && return true
    if inst isa LLVM.CallInst
        ft = inst.called_type
        return LLVM.isvararg(ft) && i > length(LLVM.parameters(ft))
    end
    return false
end

# An address that a call is given as a number (`i64`): a `ccall` passes the `Cstring` of a literal to a C function like that
# (`ccall(:strlen, Csize_t, (Cstring,), "hello")`), as the number of the address of the string. The object is in the binary, and the
# number is that of its address there.
# What a number that is the argument of a call can be the address of: the contents of a `String` (what a `Cstring` is made from) or of a `Memory` (what
# `pointer` of an array is): the pointer that is passed is to the data, and not to the length that is before it, nor to any other kind of object (a number
# that is in a symbol, a type or a struct of this process is more likely a number, see `integer_operand_is_data`)
function address_argument_objects(n::UInt)
    return [(base, delta) for (base, delta) in find_objects(n) if
            (object_type(base) === String && delta >= 8) || (object_type(base) === Symbol && delta >= 24) ||
             (object_type(base) <: Core.GenericMemory && delta >= 16)]
end

function embed_address_arguments!(e::ObjectEmbedder)
    mod = e.mod
    found = Dict{UInt,Vector{Tuple{LLVM.Instruction,Int}}}()
    for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
        inst isa LLVM.CallInst || continue
        ops = LLVM.operands(inst)
        for i in 1:length(ops)-1 # (the last is the function that is called)
            op = ops[i]
            op isa LLVM.ConstantInt && LLVM.width(LLVM.value_type(op)) == 64 || continue
            n = convert(UInt, op)
            n >= 0x10000 || continue
            integer_operand_is_data(inst, i) && continue
            isempty(address_argument_objects(n)) && continue
            push!(get!(Vector{Tuple{LLVM.Instruction,Int}}, found, n), (inst, i))
        end
    end
    changed = false
    for (addr, uses) in found
        replacement = nothing
        for (base, delta) in address_argument_objects(addr)
            replacement = try
                embed_ref!(e, base, delta)
            catch err
                err isa EmbedFailure || rethrow()
                nothing
            end
            replacement === nothing || break
        end
        replacement === nothing && continue
        number = LLVM.const_ptrtoint(replacement, LLVM.Int64Type())
        for (inst, i) in uses
            LLVM.operands(inst)[i] = number
        end
        changed = true
    end
    return changed
end

# The number of a constant that is a 64 bit integer: `i64 N`, or, where the code was not optimized as far (`--check-bounds=yes`), the
# `ptrtoint (ptr inttoptr (i64 N to ptr) to i64)` that it is made of. `nothing` if it is neither.
function number_of_address_constant(op)
    if op isa LLVM.ConstantInt
        LLVM.width(LLVM.value_type(op)) == 64 || return nothing
        return convert(UInt, op)
    end
    if op isa LLVM.ConstantExpr && LLVM.API.LLVMGetConstOpcode(op) == LLVM.API.LLVMPtrToInt
        inner = first(LLVM.operands(op))
        if inner isa LLVM.ConstantExpr && LLVM.API.LLVMGetConstOpcode(inner) == LLVM.API.LLVMIntToPtr
            n = first(LLVM.operands(inner))
            n isa LLVM.ConstantInt && LLVM.width(LLVM.value_type(n)) == 64 && return convert(UInt, n)
        end
    end
    return nothing
end

# The constants that are the numbers (`i64`) of the addresses of type objects: code compares and stores the
# type tags of objects (which are those), as numbers. As (operand number, instruction) of a pair.
function type_number_constants(mod::LLVM.Module)
    consts = Dict{UInt,Vector{Tuple{LLVM.Instruction,Int}}}()
    for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
        inst isa LLVM.SwitchInst && continue # (a case of a switch must be an integer)
        for (i, op) in enumerate(LLVM.operands(inst))
            op = number_of_address_constant(op)
            op === nothing && continue
            integer_operand_is_data(inst, i) && continue # (a count, a seed: not the tag of an object)
            n = op
            (n >= (64 << 4) && n % 16 == 0) || continue
            object_type(n) in TYPE_OBJECT_KINDS || continue # the address of a type object
            push!(get!(Vector{Tuple{LLVM.Instruction,Int}}, consts, n), (inst, i))
        end
    end
    return consts
end

# Code names a builtin type (the `Int64` in an `InexactError`, for instance) by loading its entry of the table of the
# types of the small tags, `jl_small_typeof`, at a fixed offset. When that is all that the code does with the table, each
# such load is the object of that one type, and the table itself (of which the objects of all of the types, and what they
# refer to, would be in the binary) is not needed.
function fold_small_typeof_loads!(e::ObjectEmbedder)
    mod = e.mod
    globals = LLVM.globals(mod)
    haskey(globals, "jl_small_typeof") && LLVM.isdeclaration(globals["jl_small_typeof"]) || return false
    g = globals["jl_small_typeof"]
    n = (64 << 4) ÷ sizeof(Ptr)
    loads = Tuple{LLVM.Instruction,Int}[] # each load, and the index of the entry that it loads
    function add!(inst, offset)
        offset % sizeof(Ptr) == 0 && 0 <= offset ÷ sizeof(Ptr) < n || return false
        push!(loads, (inst, offset ÷ sizeof(Ptr)))
        return true
    end
    for use in LLVM.uses(g)
        user = LLVM.user(use)
        if user isa LLVM.LoadInst
            add!(user, 0) || return false
        elseif user isa LLVM.ConstantExpr && LLVM.API.LLVMGetConstOpcode(user) == LLVM.API.LLVMGetElementPtr
            ops = LLVM.operands(user)
            length(ops) == 2 && ops[2] isa LLVM.ConstantInt || return false
            offset = convert(Int, ops[2])
            for use2 in LLVM.uses(user)
                load = LLVM.user(use2)
                load isa LLVM.LoadInst || return false
                add!(load, offset) || return false
            end
        else
            return false # (an index that is not known: the whole table is needed)
        end
    end
    isempty(loads) && return false
    table = cglobal(:jl_small_typeof, Ptr{Ptr{Cvoid}})
    ptrT = LLVM.PointerType()
    for (load, i) in loads
        p = UInt(unsafe_load(table, i + 1))
        ref = p == 0 ? nullptr() : try
            embed_ref!(e, p)
        catch err
            err isa EmbedFailure || rethrow()
            LLVM.const_inttoptr(LLVM.ConstantInt(Int64(16 * (i + 1))), ptrT)
        end
        LLVM.replace_uses!(load, ref)
        LLVM.erase!(load)
    end
    return true
end

# The table of the types of the small tags, with the types: their objects in the binary where there are
# any, and if not, an unlikely number
function define_small_typeof!(e::ObjectEmbedder)
    mod = e.mod
    globals = LLVM.globals(mod)
    haskey(globals, "jl_small_typeof") || return false
    old = globals["jl_small_typeof"]
    LLVM.isdeclaration(old) || return false
    n = (64 << 4) ÷ sizeof(Ptr)
    ptrT = LLVM.PointerType()
    table = cglobal(:jl_small_typeof, Ptr{Ptr{Cvoid}})
    entries = LLVM.Constant[]
    for i in 0:n-1
        p = UInt(unsafe_load(table, i + 1))
        push!(entries, p == 0 ? nullptr() : try
            embed_ref!(e, p)
        catch err
            err isa EmbedFailure || rethrow()
            LLVM.const_inttoptr(LLVM.ConstantInt(Int64(16 * (i + 1))), ptrT) # not an object, but not null
        end)
    end
    LLVM.name!(old, "jl_small_typeof.declaration")
    new = LLVM.GlobalVariable(mod, LLVM.ArrayType(ptrT, n), "jl_small_typeof")
    LLVM.initializer!(new, LLVM.ConstantArray(ptrT, entries))
    LLVM.constant!(new, true)
    LLVM.linkage!(new, LLVM.API.LLVMLinkOnceODRLinkage)
    LLVM.replace_uses!(old, new)
    LLVM.erase!(old)
    return true
end

# Code boxes an `Int8` or `UInt8` by indexing the table of the boxed values of libjulia (`jl_boxed_int8_cache`, `jl_boxed_uint8_cache`: 256 objects
# each) instead of allocating one. The tables are made of the objects in the binary, when the code uses them.
function define_boxed_caches!(e::ObjectEmbedder)
    mod = e.mod
    changed = false
    for name in ("jl_boxed_int8_cache", "jl_boxed_uint8_cache")
        globals = LLVM.globals(mod)
        haskey(globals, name) && LLVM.isdeclaration(globals[name]) || continue
        old = globals[name]
        ptrT = LLVM.PointerType()
        host = name == "jl_boxed_int8_cache" ? cglobal(:jl_boxed_int8_cache, Ptr{Ptr{Cvoid}}) : cglobal(:jl_boxed_uint8_cache, Ptr{Ptr{Cvoid}})
        entries = LLVM.Constant[embed_ref!(e, UInt(unsafe_load(host, i))) for i in 1:256]
        LLVM.name!(old, name * ".declaration")
        new = LLVM.GlobalVariable(mod, LLVM.ArrayType(ptrT, 256), name)
        LLVM.initializer!(new, LLVM.ConstantArray(ptrT, entries))
        LLVM.constant!(new, true)
        LLVM.linkage!(new, LLVM.API.LLVMLinkOnceODRLinkage)
        LLVM.replace_uses!(old, new)
        LLVM.erase!(old)
        changed = true
    end
    return changed
end

# The `switch`es on a type tag. (LLVM makes one of a chain of comparisons of the tag of an object with
# types, which is `tag & -16`.) The cases of a switch are numbers, which can't be the addresses of the
# types in the binary, so the switch has to become the comparisons again: one after another, and not by
# `LowerSwitchPass`, which makes a search of the cases in the order of their values, which, for the
# types in the binary, is not that of the cases.
function type_switches(mod::LLVM.Module)
    found = LLVM.SwitchInst[]
    for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
        inst isa LLVM.SwitchInst || continue
        condition = first(LLVM.operands(inst))
        condition isa LLVM.AndInst || continue
        any(op -> op isa LLVM.ConstantInt && convert(Int, op) == -16, LLVM.operands(condition)) && push!(found, inst)
    end
    return found
end

# Replace a `switch` by the comparisons of its condition with each case, one after another. The values of
# the cases are not operands of the instruction (the condition, the default block and the blocks of the
# cases are), and reading them with the C API doesn't work in the LLVM of Julia 1.14, but they are in what
# the instruction prints as.
function lower_switch!(sw::LLVM.SwitchInst)
    bb = LLVM.parent(sw)
    ops = collect(LLVM.operands(sw))
    condition, default, destinations = ops[1], ops[2], ops[3:end]
    values = [parse(Int64, m.captures[1]) for m in eachmatch(r"\bi64 (-?\d+), label", string(sw))]
    length(values) == length(destinations) || error("could not read the cases of a switch: $(string(sw))")
    n = length(destinations)

    # the block that tests each case: the first is the block of the switch
    blocks = LLVM.BasicBlock[bb]
    for i in 2:n
        push!(blocks, LLVM.BasicBlock(LLVM.after(blocks[end]), "typecase$i"))
    end
    # where each of the blocks that jumps to a block comes from (once for each jump)
    edges = Dict{Ptr{Cvoid},Vector{LLVM.BasicBlock}}()
    addedge!(to, from) = push!(get!(Vector{LLVM.BasicBlock}, edges, Ptr{Cvoid}(to.ref)), from)
    for i in 1:n
        addedge!(destinations[i], blocks[i])
    end
    addedge!(default, blocks[end])

    # the phis of the blocks that were jumped to from the switch had the block of the switch for it
    for (_, froms) in edges
    end
    LLVM.erase!(sw)
    @dispose builder = LLVM.IRBuilder() begin
        for (i, (value, destination)) in enumerate(zip(values, destinations))
            LLVM.position!(builder, LLVM.at_end(blocks[i]))
            test = LLVM.icmp!(builder, LLVM.API.LLVMIntEQ, condition, LLVM.ConstantInt(LLVM.Int64Type(), reinterpret(UInt64, value)))
            LLVM.br!(builder, test, destination, i < n ? blocks[i+1] : default)
        end
        n == 0 && (LLVM.position!(builder, LLVM.at_end(bb)); LLVM.br!(builder, default))
        for successor in unique(vcat(destinations, [default]))
            froms = edges[Ptr{Cvoid}(successor.ref)]
            for phi in collect(LLVM.instructions(successor))
                phi isa LLVM.PHIInst || break
                entries = collect(LLVM.incoming(phi))
                kept = [(v, b) for (v, b) in entries if b != bb]
                from_switch = [v for (v, b) in entries if b == bb]
                isempty(from_switch) && continue
                LLVM.position!(builder, LLVM.before(phi))
                new = LLVM.phi!(builder, LLVM.value_type(phi))
                append!(LLVM.incoming(new), vcat(kept, [(first(from_switch), b) for b in froms]))
                LLVM.replace_uses!(phi, new)
                LLVM.erase!(phi)
            end
        end
    end
    return
end

# Julia makes the objects of the constants that are numbers, characters, ... itself, as globals that have the
# type tag in them (`@jl_global_N_box = constant { tag, bytes }`), and the tag is the number of the address of
# the type, in the initializer: as in the code, it has to be the type in the binary.
function type_number_globals!(e::ObjectEmbedder)
    changed = false
    for g in LLVM.globals(e.mod)
        init = LLVM.initializer(g)
        init isa LLVM.ConstantStruct || continue
        elements = LLVM.Constant[x for x in LLVM.operands(init)]
        replaced = false
        for (i, el) in enumerate(elements)
            el isa LLVM.ConstantInt && LLVM.width(LLVM.value_type(el)) == 64 || continue
            n = convert(UInt, el)
            (n >= (64 << 4) && n % 16 == 0) || continue
            object_type(n) === DataType || continue
            ref = try
                embed_ref!(e, n)
            catch err
                err isa EmbedFailure || rethrow()
                continue
            end
            elements[i] = LLVM.const_ptrtoint(ref, LLVM.Int64Type())
            replaced = true
        end
        if replaced
            LLVM.initializer!(g, LLVM.ConstantStruct(LLVM.value_type(init), elements))
            changed = true
        end
    end
    return changed
end

embed_constants!(mod::LLVM.Module) = embed_constants!(ObjectEmbedder(mod, Dict()))

# the prefix of the names of the globals that stand for the types that code refers to while it is optimized (see `src/tags.jl`)
const TYPE_PLACEHOLDER = "static_type_"

# The address of the object that a constant stands for: `inttoptr (i64 N to ptr)` (possibly with an offset), or the global that stands for a
# type while the code is optimized (see `TYPE_PLACEHOLDER`); `nothing` if it is neither
function constant_object_address(op)
    if op isa LLVM.GlobalVariable
        name = LLVM.name(op)
        startswith(name, TYPE_PLACEHOLDER) || return nothing
        return tryparse(UInt, name[length(TYPE_PLACEHOLDER)+1:end]; base = 16)
    end
    nodes = inttoptr_nodes(op)
    if length(nodes) == 1
        addr = constant_address(nodes[1])
        return addr === nothing ? nothing : UInt(addr)
    end
    # (an offset of a type that stands for it: `getelementptr (i8, @static_type_N, 16)`)
    if isempty(nodes) && op isa LLVM.ConstantExpr && !isempty(LLVM.operands(op))
        return constant_object_address(LLVM.operands(op)[1])
    end
    return nothing
end

# The objects of the types that were globals while the code was optimized: the object that is in the binary, or the number of
# the type in this process (which is what it was) if it can't be there
function resolve_type_placeholders!(e::ObjectEmbedder)
    mod = e.mod
    placeholders = [g for g in LLVM.globals(mod) if startswith(LLVM.name(g), TYPE_PLACEHOLDER)]
    isempty(placeholders) && return false
    ptrT = LLVM.PointerType()
    for g in placeholders
        addr = parse(UInt, LLVM.name(g)[length(TYPE_PLACEHOLDER)+1:end]; base = 16)
        ref = try
            embed_ref!(e, addr)
        catch err
            err isa EmbedFailure || rethrow()
            LLVM.const_inttoptr(LLVM.ConstantInt(Int64(addr)), ptrT)
        end
        LLVM.replace_uses!(g, ref)
        LLVM.erase!(g)
    end
    return true
end

function embed_constants!(e::ObjectEmbedder)
    mod = e.mod
    resolve_type_placeholders!(e)
    # as comparisons, so that the types in them can be replaced (see `type_number_constants`)
    foreach(lower_switch!, type_switches(mod))
    changed = fold_small_typeof_loads!(e) || define_small_typeof!(e)
    changed |= define_boxed_caches!(e)
    consts = inttoptr_constants(mod)
    for (addr, ops) in consts
        replacement = nothing
        for (base, delta) in find_objects(addr)
            # embedding may fail halfway, leaving globals behind that nothing refers to
            replacement = try
                embed_ref!(e, base, delta)
            catch err
                if err isa EmbedFailure
                    isempty(err.reason) || @debug "Cannot embed an object" reason = err.reason
                else
                    @debug "Could not embed object" address=base type=object_type(base) exception=(err, catch_backtrace())
                end
                nothing
            end
            replacement === nothing || break
        end
        replacement === nothing && continue
        @debug "Embedded the object of an address constant" address = string(addr, base = 16) objects = [(string(b, base = 16), d, object_type(b)) for (b, d) in find_objects(addr)]
        for op in ops
            LLVM.replace_uses!(op, replacement)
        end
        changed = true
    end
    # the numbers of the addresses of types: the objects of the types are in the binary
    for (addr, uses) in type_number_constants(mod)
        ref = try
            embed_ref!(e, addr)
        catch err
            err isa EmbedFailure || rethrow()
            @debug "The number of the address of a type stays, as the type is not in the binary" address = string(addr, base = 16) type = object_type(addr) reason = err.reason
            continue
        end
        number = LLVM.const_ptrtoint(ref, LLVM.Int64Type())
        for (inst, i) in uses
            LLVM.operands(inst)[i] = number
        end
        changed = true
    end
    changed |= type_number_globals!(e)
    changed |= embed_address_arguments!(e)
    # drop the globals of objects that failed, and of objects only they referred to
    while true
        dead = [g for g in LLVM.globals(mod) if startswith(LLVM.name(g), "static_object_") && isempty(LLVM.uses(g))]
        isempty(dead) && break
        foreach(LLVM.erase!, dead)
    end
    changed |= define_symbol_table!(e)
    changed |= define_symbol_texts!(e)
    return changed
end

# whether a name is a plain ASCII identifier, which is written `:name` by `show` (the same test is made for the symbols of the program, in `show.jl`)
function plain_symbol_name(name)
    isempty(name) && return false
    for (i, c) in enumerate(name)
        isalpha = (UInt8('a') <= c <= UInt8('z')) || (UInt8('A') <= c <= UInt8('Z')) || c == UInt8('_')
        isother = (UInt8('0') <= c <= UInt8('9')) || c == UInt8('!')
        (isalpha || (i > 1 && isother)) || return false
    end
    return true
end

# The symbols of the binary: (name, its global, the address in this process), sorted by name (by the bytes, the shorter first, as
# `compare_symbol_name` in `symbols.jl` does)
function embedded_symbol_globals(mod::LLVM.Module)
    found = Tuple{Vector{UInt8},LLVM.GlobalVariable,UInt}[]
    for g in LLVM.globals(mod)
        name = LLVM.name(g)
        startswith(name, "static_object_") || continue
        addr = tryparse(UInt, first(split(name[15:end], '.')), base = 16)
        (addr === nothing || object_type(addr) !== Symbol) && continue
        len = Int(ccall(:strlen, Csize_t, (Ptr{UInt8},), Ptr{UInt8}(addr + 24)))
        push!(found, (copy(unsafe_wrap(Array, Ptr{UInt8}(addr + 24), len)), g, addr))
    end
    return sort!(found; by = first)
end

# Replace the reference (a declaration) that the code has to a list of symbols by the list: a constant `{ count, words... }`
function define_symbol_list!(mod::LLVM.Module, name::AbstractString, words::Vector{LLVM.Constant})
    old = get(LLVM.globals(mod), name, nothing)
    old === nothing && return false
    table = LLVM.ConstantArray(LLVM.Int64Type(), words)
    new = LLVM.GlobalVariable(mod, LLVM.value_type(table), string(name, "_list"))
    LLVM.initializer!(new, table)
    LLVM.constant!(new, true)
    LLVM.linkage!(new, LLVM.API.LLVMInternalLinkage)
    LLVM.replace_uses!(old, new)
    LLVM.erase!(old)
    return true
end

symbol_address(g) = LLVM.const_ptrtoint(LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER)]), LLVM.Int64Type())

# The symbols that are in the binary, as the list that `Symbol(string)` looks in (see `symbols.jl`): { count, the address of each symbol },
# sorted by name. Only if the code has the reference that asks for it (`_static_symbols`): the list keeps all the symbols alive.
function define_symbol_table!(e::ObjectEmbedder)
    haskey(LLVM.globals(e.mod), "_static_symbols") || return false
    found = embedded_symbol_globals(e.mod)
    return define_symbol_list!(e.mod, "_static_symbols", LLVM.Constant[i64(length(found)), (symbol_address(g) for (_, g, _) in found)...])
end

# The text that `show` of a symbol writes, for the symbols of the binary that it is not `:name` for (an operator, a name that is not an identifier,
# one with characters other than ASCII): what Julia writes, which is decided by tables of its parser that are not in the binary. As
# { count, (the address of the symbol, the address of the text as a C string)... }, sorted by name.
function define_symbol_texts!(e::ObjectEmbedder)
    mod = e.mod
    haskey(LLVM.globals(mod), "_static_symbol_texts") || return false
    words = LLVM.Constant[]
    n = 0
    for (name, g, addr) in embedded_symbol_globals(mod)
        plain_symbol_name(name) && continue
        text = repr(unsafe_pointer_to_objref(Ptr{Cvoid}(addr))::Symbol)
        bytes = LLVM.ConstantDataArray(LLVM.Int8Type(), UInt8[codeunits(text)..., 0x00])
        tg = LLVM.GlobalVariable(mod, LLVM.value_type(bytes), "static_symbol_text_$n")
        LLVM.initializer!(tg, bytes)
        LLVM.constant!(tg, true)
        LLVM.linkage!(tg, LLVM.API.LLVMInternalLinkage)
        push!(words, symbol_address(g), LLVM.const_ptrtoint(tg, LLVM.Int64Type()))
        n += 1
    end
    return define_symbol_list!(mod, "_static_symbol_texts", LLVM.Constant[i64(n), words...])
end
