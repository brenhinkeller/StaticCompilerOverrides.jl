# Slots that hold values of an abstract type: what is stored in them.
#
# The elements of a `Vector{Any}`, and the fields of a struct that are of the type `Any` or an abstract type, hold values of types that inference does not know, so what is read from them is an `Any`, and a call
# on it is made over the *registered* types (see dispatch.jl): a value of another type aborts the program. The types that the slot holds are the types of what the program stores in it, all of which are in the code that
# is compiled (and in the constants that it refers to): `Any[1, "a", (2, 3.5)]` holds an `Int`, a `String` and a `Tuple{Int,Float64}`. This finds them, and says what it found (it does not change what is compiled yet).
#
# A slot is the elements of one type of memory (`Memory{Any}`: all the `Vector{Any}` and the `Dict{K,Any}` of the program are one), or the field of a struct (`RefValue{Any}.x`, a field of the type `Any` of a struct of
# the program). The key of a slot is `(:elem, T, nothing)` or `(:field, S, name)`.

const SlotKey = Tuple{Symbol,Any,Any}

# the types that the slots held in the compilation that is made now: the union of the types of what was stored, or `Any` when something of a type that is not known was (so that what the slot holds is not known)
const SEEN_SLOTS = Dict{SlotKey,Any}()
const SLOT_LIMIT = Ref(64)
# `:on` (the types are used), `:observe` (found and kept in `SEEN_SLOTS`, and not used), `:off`: `STATIC_RUNTIME_SLOTS` is `1`/unset, `observe` or `0`
const SLOTS_MODE = Ref(:on)

# The types that reads of each slot are given in this compilation (see `update_slot_types!`), the slots that are given up (what is stored in them is not known: a read of one is an `Any`, over the registered types), and the
# slots that something of a type that is not known was stored in, in the pass that was made last
const SLOT_TYPES = Dict{SlotKey,Any}()
const SLOT_OPEN = Set{SlotKey}()
const SEEN_UNKNOWN = Set{SlotKey}()
const SLOT_PASSES = Ref(0)
const SLOT_PASS_LIMIT = 4

# Whether this compilation has called anything over the registered types (a value of the type `Any` that it dispatched on): when it has not, there is nothing that the types of the slots would change
const REGISTERED_DISPATCH_USED = Ref(false)
# The keys of the inference cache (`OverridesParams`) that this was true for: what is inferred before is taken from the cache, where this is not seen again
const DISPATCH_PARAMS = Set{Int}()
function note_dispatch_used!()
    REGISTERED_DISPATCH_USED[] = true
    push!(DISPATCH_PARAMS, OverridesParams().candidates)
    return
end
dispatch_was_used() = REGISTERED_DISPATCH_USED[] || OverridesParams().candidates in DISPATCH_PARAMS

# said when the types of the slots have changed, so that the compilation is made again with them (the pass is cut short: inference is what they are found from)
struct SlotsChanged <: Exception end

# A hash of the types of the slots, for the key of the inference cache. (`hash` of a `Union` does not tell unions apart, so this is made of the objectids of the types in them. The order does not matter.)
function slots_hash()
    h = UInt(0)
    for (k, T) in SLOT_TYPES
        members = sort!(UInt[objectid(t) for t in Base.uniontypes(T)])
        h += hash(members, hash(objectid(k[2]), hash(k[1], hash(k[3]))))
    end
    return hash(length(SLOT_TYPES), h)
end

# at the start of each pass of the compilation
function reset_slots_pass!()
    empty!(SEEN_SLOTS)
    empty!(SEEN_UNKNOWN)
    return
end

function reset_slots!()
    empty!(SLOT_TYPES)
    empty!(SLOT_OPEN)
    empty!(SEEN_SLOTS)
    empty!(SEEN_UNKNOWN)
    SLOT_PASSES[] = 0
    mode = get(ENV, "STATIC_RUNTIME_SLOTS", "on")
    SLOTS_MODE[] = mode == "0" ? :off : mode == "observe" ? :observe : :on
    return
end

# whether what is read from a slot of the declared type `T` has a type that is not known: `Any`, an abstract type, a union with one of them. (A concrete type, and a union of them, are known already.)
needs_slot_type(@nospecialize(T)) = !(isconcretetype(T) || (T isa Union && all(isconcretetype, Base.uniontypes(T))) || T <: Type)

# whether a type is one that a slot can be said to hold: concrete, or a union of them
closed_type(@nospecialize(T)) = all(isconcretetype, Base.uniontypes(T))

function note_slot_store!(key::SlotKey, @nospecialize(T))
    T === Union{} && return
    cur = get!(SEEN_SLOTS, key, Union{})
    if !closed_type(T)
        push!(SEEN_UNKNOWN, key)
        return
    end
    new = Union{cur, T}
    Base.unionlen(new) > SLOT_LIMIT[] ? push!(SEEN_UNKNOWN, key) : (SEEN_SLOTS[key] = new)
    return
end

# the key of the memory that a reference of the type `R` is of (`GenericMemoryRef{:not_atomic,Any,...}`), or `nothing` if what it holds is of a type that is known
function elem_slot_key(@nospecialize(R))
    R = CC.widenconst(R)
    R isa DataType && R <: Core.GenericMemoryRef && length(R.parameters) >= 2 || return nothing
    T = R.parameters[2]
    T isa Type && needs_slot_type(T) || return nothing
    return (:elem, T, nothing)
end

# the key of the field `name` (a symbol or a number) of a struct of the type `S`, or `nothing` if it is of a type that is known
function field_slot_key(@nospecialize(S), @nospecialize(name))
    S = CC.widenconst(S)
    S isa DataType && isconcretetype(S) && !(S <: Tuple) && !(S <: Type) && isstructtype(S) || return nothing
    idx = name isa Symbol ? Base.fieldindex(S, name, false) : name isa Integer ? Int(name) : 0
    1 <= idx <= fieldcount(S) || return nothing
    needs_slot_type(fieldtype(S, idx)) || return nothing
    return (:field, S, fieldname(S, idx))
end

# the type of an operand of a statement of optimized code, where the arguments are those of the specialization of the method
function slot_operand_type(src::Core.CodeInfo, mi::Core.MethodInstance, x)
    if x isa Core.Argument
        sig = Base.unwrap_unionall(mi.specTypes)
        sig isa DataType && x.n <= length(sig.parameters) || return Any
        T = sig.parameters[x.n]
        return T isa Core.TypeofVararg ? Any : T
    end
    return operand_type(src, x)
end

# the stores of a method (its optimized statements, with their types)
function learn_slots!(src::Core.CodeInfo, mi::Core.MethodInstance)
    code = src.code
    for pc in eachindex(code)
        st = code[pc]
        call = st isa Expr && st.head === :(=) && length(st.args) == 2 ? st.args[2] : st
        call isa Expr || continue
        if call.head === :call && length(call.args) >= 3
            f = called_function(code, call.args[1])
            if f === Core.memoryrefset! && length(call.args) >= 3
                key = elem_slot_key(slot_operand_type(src, mi, call.args[2]))
                key === nothing || note_slot_store!(key, slot_operand_type(src, mi, call.args[3]))
            elseif f === Core.memoryrefmodify! || f === Core.memoryrefswap! || f === Core.memoryrefreplace! || f === Core.memoryrefsetonce!
                key = elem_slot_key(slot_operand_type(src, mi, call.args[2]))
                key === nothing || note_slot_store!(key, Any)
            elseif f === Core.setfield! && length(call.args) >= 4
                name = call.args[3] isa QuoteNode ? call.args[3].value : call.args[3] isa Integer ? call.args[3] : nothing
                S = slot_operand_type(src, mi, call.args[2])
                if name === nothing
                    # (a field that is not known when compiling: any of the fields that hold an unknown type may be it)
                    S isa DataType && isconcretetype(S) && isstructtype(S) &&
                        for i in 1:fieldcount(S); needs_slot_type(fieldtype(S, i)) && note_slot_store!((:field, S, fieldname(S, i)), Any); end
                else
                    key = field_slot_key(S, name)
                    key === nothing || note_slot_store!(key, slot_operand_type(src, mi, call.args[4]))
                end
            end
        elseif call.head === :new && length(call.args) >= 2
            S = called_function(code, call.args[1])
            S isa DataType && isconcretetype(S) && isstructtype(S) && !(S <: Tuple) || continue
            for (i, a) in enumerate(call.args[2:end])
                i <= fieldcount(S) || break
                needs_slot_type(fieldtype(S, i)) || continue
                note_slot_store!((:field, S, fieldname(S, i)), slot_operand_type(src, mi, a))
            end
        end
    end
    return
end

# What the constants that the code refers to hold in these slots: the elements of an array of `Any`, the fields of a struct that are of an abstract type
function note_slots_in!(@nospecialize(x), depth::Int = 0, budget::Base.RefValue{Int} = Ref(2000), seen = Base.IdSet{Any}())
    budget[] <= 0 && return
    budget[] -= 1
    (x isa Type || x isa Module || x isa Symbol || x isa String || x isa Number || x isa Char || depth >= 4) && return
    ismutable(x) && (x in seen ? (return) : push!(seen, x))
    if x isa Core.GenericMemory
        key = (:elem, eltype(x), nothing)
        if needs_slot_type(eltype(x))
            for i in eachindex(x)
                isassigned(x, i) || continue
                note_slot_store!(key, typeof(x[i]))
                note_slots_in!(x[i], depth + 1, budget, seen)
            end
        elseif !isbitstype(eltype(x))
            for i in eachindex(x)
                isassigned(x, i) && note_slots_in!(x[i], depth + 1, budget, seen)
            end
        end
    elseif x isa Tuple
        for e in x
            note_slots_in!(e, depth + 1, budget, seen)
        end
    elseif isstructtype(typeof(x)) && !(x isa Core.CodeInstance) && !(x isa Core.MethodInstance) && !(x isa Method) && !(x isa Core.TypeName) && fieldcount(typeof(x)) <= 16
        S = typeof(x)
        for i in 1:fieldcount(S)
            isdefined(x, i) || continue
            v = getfield(x, i)
            needs_slot_type(fieldtype(S, i)) && note_slot_store!((:field, S, fieldname(S, i)), typeof(v))
            note_slots_in!(v, depth + 1, budget, seen)
        end
    end
    return
end

function note_slots_in_constants!(code)
    for st in code
        st isa Expr || continue
        skip = st.head === :call ? 2 : st.head === :invoke ? 3 : st.head === :new ? 2 : st.head === :foreigncall ? 0 : 1
        skip == 0 && continue
        for i in skip:length(st.args)
            a = st.args[i]
            v = a isa GlobalRef ? (isdefined(a.mod, a.name) && isconst(a.mod, a.name) ? getglobal(a.mod, a.name) : nothing) :
                a isa QuoteNode ? a.value : a isa Core.SSAValue || a isa Core.Argument || a isa Expr ? nothing : a
            v === nothing && continue
            note_slots_in!(v)
        end
    end
    return
end

## the passes

# Run after inference (the types of all that is reached are in the cache, with the optimized code: what `juliac --trim` looks at, so that what is found is of what the program reaches, and does not depend on which methods were
# inferred in this pass and which were taken from the cache): the stores of the slots in the code that the program reaches, and what the reads of them are given in the next pass (`update_slot_types!`), until what is found is
# what was used
function analyze_slots!(interp, root)
    SLOTS_MODE[] === :off && return
    (isempty(SLOT_TYPES) && !dispatch_was_used() && SLOTS_MODE[] !== :observe) && return
    # (what the roots that were made before in this pass stored is kept: a `@cfunction` is a root of its own, and the slots are those of the whole program)
    for (ci, src) in GPUCompiler.CompilerCaching.get_codeinfos(interp, root)
        src isa Core.CodeInfo && ci.def isa Core.MethodInstance || continue
        learn_slots!(src, ci.def)
        note_slots_in_constants!(src.code)
    end
    SLOTS_MODE[] === :observe && return
    changed = update_slot_types!()
    changed || return
    SLOT_PASSES[] += 1
    if SLOT_PASSES[] > SLOT_PASS_LIMIT
        # (it does not settle: the compilation is made as if there were no slots)
        empty!(SLOT_TYPES)
        SLOTS_MODE[] = :off
    end
    throw(SlotsChanged())
end

function GPUCompiler.drive_inference!(interp::OverridesInterpreter, mi::Core.MethodInstance)
    root = @invoke GPUCompiler.drive_inference!(interp::CC.AbstractInterpreter, mi::Core.MethodInstance)
    root isa Core.CodeInstance && analyze_slots!(interp, root)
    return root
end

# The types that the reads of the slots are given next, from what was stored in them in the pass that was made: the first time, the types that are known of what was stored (what is stored that is read from a slot
# is of a type that is not known in that pass, as an `Any`, and is not counted); after that, what was stored with the reads as they were given has to be of those types: if it is, they are the ones; if it is of other types, those
# are added; if something that is of a type that is not known is stored, the slot is given up. Returns whether any changed.
function update_slot_types!()
    changed = false
    for (k, T) in SEEN_SLOTS
        k in SLOT_OPEN && continue
        used = get(SLOT_TYPES, k, nothing)
        if used === nothing
            T === Union{} && continue
            SLOT_TYPES[k] = T
            changed = true
        elseif k in SEEN_UNKNOWN
            delete!(SLOT_TYPES, k)
            push!(SLOT_OPEN, k)
            changed = true
        elseif T === Union{} || T === used
            continue
        elseif T <: used
            SLOT_TYPES[k] = T
            changed = true
        else
            new = Union{used, T}
            if Base.unionlen(new) > SLOT_LIMIT[]
                delete!(SLOT_TYPES, k)
                push!(SLOT_OPEN, k)
            else
                SLOT_TYPES[k] = new
            end
            changed = true
        end
    end
    return changed
end

# the type that a read of a slot is given, or `nothing`
# The type of a read from a slot of the types that were stored in it, as precise as what inference had for it before (`rt`): the part of it that is of the types that the declared type has
function refined_read(@nospecialize(T), @nospecialize(rt))
    R = typeintersect(T, CC.widenconst(rt))
    return R === Union{} ? rt : R
end

slot_read_type(key) = SLOTS_MODE[] === :on ? get(SLOT_TYPES, key, nothing) : nothing

# What was found, as lines to read: the slot, and the types (or that they are not known)
function slots_report(io::IO = stdout)
    for (key, T) in sort!(collect(SEEN_SLOTS); by = p -> string(p[1]))
        what = key[1] === :elem ? string("elements of Memory{", key[2], "}") : string(key[2], ".", key[3])
        println(io, rpad(what, 60), T === Any ? "NOT KNOWN" : string(Base.unionlen(T), " types: ", T))
    end
end
