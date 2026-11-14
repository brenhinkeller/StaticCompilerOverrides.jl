# Boxes with the type of what they hold.
#
# A variable that a closure takes and that is assigned more than once (or after the closure is made) is a `Core.Box`, which holds a value of any type: what is read from it is an `Any`, and what
# is done with that is a call that is not known when compiling (a dispatch on the registered types, at best). `viewport = Observable(...)` in the constructor of a `Scene` of Makie, which a closure
# takes, is one. Julia does not give what is read from a box the type of what is assigned to the variable, though it is a `Union{Nothing,Observable{Rect2i}}` in every place that it is assigned.
#
# What is read from a box (`getfield(box, :contents)`) is given that type here: the union of the types of what is assigned to the variable, which is what compiling found the last time (the passes of
# `with_function_candidates`: what the first one finds, with the reads of the boxes as `Any`, is what the second one is made with, and so on until they say the same). A closure has the box as a field
# (a `Core.Box`, whatever the variable is), so the type is also kept for the field of the closure, and a read from it in the code of the closure has it. That is only done for a box that nothing but the
# function and the closures that it makes reads and assigns, and that none of those closures assigns (what a closure assigns is not known until it has been inferred, with the type of the box).

# (the specialization of a method, the number of the box among those that its code makes), and (the type of a closure, the name of its field that is a box) => the type of what the box holds
const BOX_TYPES = Dict{Tuple{Any,Union{Int,Symbol}},Any}()
const SEEN_BOXES = Dict{Tuple{Any,Union{Int,Symbol}},Any}()
# (what is found is kept from one compilation to the next: a method has the same boxes in all of them, and what is inferred is kept for the number of this version of the types, so that what was
# found when it was inferred is not lost when it is used again)
const BOX_VERSION = Ref(0)
# the boxes whose type could not be found (what is assigned to them is of a type that is not known, even when the type of what they hold is): they stay `Core.Box`
const BOX_GAVE_UP = Set{Tuple{Any,Union{Int,Symbol}}}()

# A variable that is assigned from itself (`y = y * 2`) is of the type of what it is assigned if it is assigned only things of that type: the first time the code is inferred what is read
# from the box is an `Any`, so a value that is made from it is too, and is not counted. The next time the box holds the type that the rest were, and what is assigned is of that type or not:
# if it is not, the type is made a union of the two, and if that is not one that is known (an `Any`) the box is left as it is.

# `slot = Core.Box(args...)`: the slot and the call
function box_creation(code, st)
    st isa Expr && st.head === :(=) && length(st.args) == 2 && st.args[1] isa Core.SlotNumber || return nothing
    call = st.args[2]
    call isa Expr && call.head === :call && called_function(code, call.args[1]) === Core.Box || return nothing
    return st.args[1].id, call
end

# the slot that a statement reads (`_7`), or `nothing`
slot_read(code, x) = x isa Core.SlotNumber ? x.id : (x isa Core.SSAValue && code[x.id] isa Core.SlotNumber ? code[x.id].id : nothing)

function operand_type(src::Core.CodeInfo, x)
    if x isa Core.SSAValue
        t = src.ssavaluetypes isa Vector ? src.ssavaluetypes[x.id] : Any
        return CC.widenconst(t)
    elseif x isa Core.SlotNumber
        return src.slottypes isa Vector ? CC.widenconst(src.slottypes[x.id]) : Any
    elseif x isa Core.Argument
        return src.slottypes isa Vector ? CC.widenconst(src.slottypes[x.n]) : Any
    elseif x isa QuoteNode
        return typeof(x.value)
    elseif x isa GlobalRef
        return Any
    elseif x isa Core.BindingPartition
        # (the code refers to a global through its binding partition: a constant has the type of its value)
        f = called_function(nothing, x)
        return f === nothing && !((x.kind & 0x0f) in (Base.PARTITION_KIND_CONST, Base.PARTITION_KIND_CONST_IMPORT, Base.PARTITION_KIND_IMPLICIT_CONST, Base.PARTITION_KIND_BACKDATED_CONST)) ? Any : typeof(f)
    elseif x isa Expr
        return Any
    else
        return typeof(x)
    end
end

# whether a closure of this type (or one that it makes) assigns a variable that it took: `setfield!(box, :contents, value)`
function closure_assigns_box(T, world::UInt, seen::Set{Any}, depth::Int = 0)
    T isa Type || return true
    T in seen && return false
    push!(seen, T)
    depth > 4 && return true
    ms = Base._methods_by_ftype(Tuple{Base.unwrap_unionall(T), Vararg{Any}}, nothing, -1, world)
    ms isa Vector || return true
    for mm in ms
        m = (mm::Core.MethodMatch).method
        isdefined(m, :source) || isdefined(m, :generator) && return true
        src = try Base.uncompressed_ast(m) catch; return true end
        code = src.code
        for st in code
            call = st isa Expr && st.head === :(=) && length(st.args) == 2 ? st.args[2] : st
            call isa Expr || continue
            if call.head === :call && length(call.args) >= 4 && called_function(code, call.args[1]) === Core.setfield! &&
               call.args[3] isa QuoteNode && call.args[3].value === :contents
                return true
            elseif call.head === :new && length(call.args) >= 2
                C = called_function(code, call.args[1])
                C isa Type && C !== Core.Box && closure_assigns_box(C, world, seen, depth + 1) && return true
            end
        end
    end
    return false
end

# The statements that are made from what is read from the box in `slot`, directly or through other statements and variables: their types are those of the code inferred with the box as it was, so they say nothing about what
# the box holds (a value made from an `Any` is a union of whatever the registered types make of it)
function box_dependents(code, slot::Int)
    ssa = Set{Int}()
    slots = Set{Int}()
    refs(x) = (x isa Core.SSAValue && x.id in ssa) || (x isa Core.SlotNumber && x.id in slots)
    changed = true
    while changed
        changed = false
        for (pc, st) in enumerate(code)
            call = st isa Expr && st.head === :(=) && length(st.args) == 2 ? st.args[2] : st
            call isa Expr || (call isa Core.SSAValue && refs(call) && !(pc in ssa) && (push!(ssa, pc); changed = true); continue)
            tainted = false
            if call.head === :call && length(call.args) >= 3 && call.args[3] isa QuoteNode && call.args[3].value === :contents &&
               called_function(code, call.args[1]) === Core.getfield && slot_read(code, call.args[2]) == slot
                tainted = true
            elseif any(refs, call.args)
                tainted = true
            end
            tainted || continue
            pc in ssa || (push!(ssa, pc); changed = true)
            if st isa Expr && st.head === :(=) && st.args[1] isa Core.SlotNumber && !(st.args[1].id in slots)
                push!(slots, st.args[1].id)
                changed = true
            end
        end
    end
    return ssa, slots
end

# the closures that were made with the box, as the type of the field that it is: `closures` are the type of each and the place of the box in the call that makes it
function record_closure_fields!(closures, code, T)
    for (C, i) in closures
        C isa DataType && 1 <= i <= fieldcount(C) && fieldtype(C, i) === Core.Box || continue
        SEEN_BOXES[(C, fieldname(C, i))] = T
    end
end

# The types of what each box of the code holds, as far as that can be known: `SEEN_BOXES`. (Run after the code has been inferred, before it is optimized: the statements are those of the
# lowered code, with their types.)
function learn_boxes!(src::Core.CodeInfo, mi::Core.MethodInstance)
    code = src.code
    created = Dict{Int,Int}()   # slot => number of the box
    ambiguous = Set{Int}()
    n = 0
    for st in code
        b = box_creation(code, st)
        b === nothing && continue
        n += 1
        haskey(created, b[1]) ? push!(ambiguous, b[1]) : (created[b[1]] = n)
    end
    isempty(created) && return
    types = Dict{Int,Vector{Any}}(s => Any[] for s in keys(created))
    free = Dict{Int,Vector{Any}}(s => Any[] for s in keys(created)) # (those that are not made from what is read from the box)
    unsafe = Set{Int}(ambiguous)
    closures = Dict{Int,Vector{Any}}(s => Any[] for s in keys(created))
    dependents = Dict{Int,Tuple{Set{Int},Set{Int}}}(s => box_dependents(code, s) for s in keys(created))
    independent(box, x) = !((x isa Core.SSAValue && x.id in dependents[box][1]) || (x isa Core.SlotNumber && x.id in dependents[box][2]))
    for (pc, st) in enumerate(code)
        b = box_creation(code, st)
        if b !== nothing
            for a in b[2].args[2:end]
                push!(types[b[1]], operand_type(src, a))
                independent(b[1], a) && push!(free[b[1]], operand_type(src, a))
            end
            continue
        end
        st isa Expr || continue
        # (a statement that only reads the slot, `%3 = _7`, is how it is used: the uses are those of that value)
        call = st.head === :(=) && length(st.args) == 2 ? st.args[2] : st
        call isa Expr || continue
        if call.head === :call
            f = called_function(code, call.args[1])
            box = length(call.args) >= 2 ? slot_read(code, call.args[2]) : nothing
            if box !== nothing && haskey(created, box) && length(call.args) >= 3 && call.args[3] isa QuoteNode && call.args[3].value === :contents &&
               (f === Core.getfield || f === Core.isdefined || f === Core.setfield!)
                if f === Core.setfield! && length(call.args) >= 4
                    push!(types[box], operand_type(src, call.args[4]))
                    independent(box, call.args[4]) && push!(free[box], operand_type(src, call.args[4]))
                end
                continue
            end
        elseif call.head === :new
            C = called_function(code, call.args[1])
            for (i, a) in enumerate(call.args[2:end])
                box = slot_read(code, a)
                box !== nothing && haskey(created, box) && push!(closures[box], (C, i))
            end
            continue
        end
        # any other use of the box (an argument of a call, ...): not known what is done with it
        for a in call.args
            box = slot_read(code, a)
            box !== nothing && haskey(created, box) && !(code[pc] isa Core.SlotNumber) && push!(unsafe, box)
        end
    end
    world = Base.get_world_counter()
    for (slot, k) in created
        slot in unsafe && continue
        key = (mi.specTypes, k)
        key in BOX_GAVE_UP && continue
        any(c -> !(c[1] isa Type) || closure_assigns_box(c[1], world, Set{Any}()), closures[slot]) && (push!(BOX_GAVE_UP, key); continue)
        used = get(BOX_TYPES, key, nothing)
        stored = Any[t for t in types[slot] if t !== Union{}]
        if used === nothing
            T = Union{}
            for t in free[slot]
                (t === Union{} || t === Any) && continue
                T = Union{T, t}
            end
            (T === Union{} || Base.unionlen(T) > 8) && continue
            SEEN_BOXES[key] = T
            record_closure_fields!(closures[slot], code, T)
        else
            bad = Any[t for t in stored if !(t <: used)]
            if isempty(bad)
                SEEN_BOXES[key] = used
                record_closure_fields!(closures[slot], code, used)
            else
                T = Union{used, bad...}
                if T === Any || any(t -> t === Any, bad) || Base.unionlen(T) > 8
                    push!(BOX_GAVE_UP, key)
                    SEEN_BOXES[key] = Any # (said so that the next pass leaves the box as it is)
                    record_closure_fields!(closures[slot], code, Any)
                else
                    SEEN_BOXES[key] = T
                    record_closure_fields!(closures[slot], code, T)
                end
            end
        end
    end
    return
end

# the number of the box that a slot is, among those that the code makes (`slot = Core.Box()`): for the code of a method
const BOX_SLOTS = Dict{Any,Dict{Int,Int}}()
function box_slots(src::Core.CodeInfo, mi::Core.MethodInstance)
    get!(BOX_SLOTS, (mi.specTypes, length(src.code))) do
        d = Dict{Int,Int}()
        n = 0
        for st in src.code
            b = box_creation(src.code, st)
            b === nothing && continue
            n += 1
            d[b[1]] = haskey(d, b[1]) ? -1 : n
        end
        d
    end
end

# The type of what is read from a box, `getfield(box, :contents)`, where it is known: `x` is the box as the statement has it (a slot of the method that made it, or a field of the closure that took it)
function box_content_type(sv, @nospecialize(x))
    isempty(BOX_TYPES) && return nothing
    src = sv.src
    code = src.code
    mi = sv.linfo
    mi isa Core.MethodInstance || return nothing
    e = x isa Core.SSAValue && x.id <= length(code) ? code[x.id] : x
    if e isa Core.SlotNumber
        n = get(box_slots(src, mi), e.id, 0)
        n > 0 || return nothing
        T = get(BOX_TYPES, (mi.specTypes, n), nothing)
        return T === Any ? nothing : T
    elseif e isa Expr && e.head === :call && length(e.args) == 3 && e.args[3] isa QuoteNode && called_function(code, e.args[1]) === Core.getfield
        self = e.args[2]
        (self isa Core.SlotNumber && self.id == 1) || (self isa Core.Argument && self.n == 1) || return nothing
        C = mi.specTypes.parameters[1]
        T = get(BOX_TYPES, (C, e.args[3].value), nothing)
        return T === Any ? nothing : T
    end
    return nothing
end

function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.getfield), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    call = @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
    isempty(BOX_TYPES) && return call
    sv isa CC.InferenceState || return call
    argtypes = arginfo.argtypes
    length(argtypes) == 3 || return call
    t = argtypes[3]
    T = nothing
    if CC.widenconst(argtypes[2]) === Core.Box
        (t isa Core.Const && t.val === :contents) || return call
        arginfo.fargs === nothing && return call
        T = box_content_type(sv, arginfo.fargs[2])
    elseif t isa Core.Const && (t.val isa Symbol || t.val isa Integer)
        # (a field of an abstract type: what has been stored in it, see slots.jl)
        key = field_slot_key(argtypes[2], t.val)
        key === nothing || (T = slot_read_type(key))
    end
    T === nothing && return call
    return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
        return CC.CallMeta(refined_read(T, result.rt), result.exct, result.effects, result.info, result.refinements)
    end
end

# What is read from the elements of a memory of an abstract type (`Memory{Any}`) is of the types that were stored in them (see slots.jl)
function CC.abstract_call_known(interp::OverridesInterpreter, f::typeof(Core.memoryrefget), arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int = CC.get_max_methods(interp, f, sv))
    call = @invoke CC.abstract_call_known(interp::CC.AbstractInterpreter, f::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo,
                                          vtypes::Union{Nothing,Vector{CC.VarState}}, sv::CC.AbsIntState, max_methods::Int)
    isempty(SLOT_TYPES) && return call
    sv isa CC.InferenceState || return call
    length(arginfo.argtypes) >= 2 || return call
    key = elem_slot_key(arginfo.argtypes[2])
    key === nothing && return call
    T = slot_read_type(key)
    T === nothing && return call
    return CC.Future{CC.CallMeta}(call, interp, sv) do result, interp, sv
        return CC.CallMeta(refined_read(T, result.rt), result.exct, result.effects, result.info, result.refinements)
    end
end
