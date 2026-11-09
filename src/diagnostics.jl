# Why an entry point can't be compiled when its return type is not concrete.
#
# StaticCompiler stops with "did not infer to a concrete type. Got `Union{}`", which does not say what in the program makes it so. The most
# common causes are a call that always throws (or that no method fits, as far as the compiler can tell), and a value whose type is only known when
# the program runs (`Val(n)` of a variable, a type that has a size in it that is computed, a collection of an abstract type). Before the call
# to StaticCompiler the entry point is inferred (the result is kept, so that it costs little), and when it is not concrete, the calls that it
# is made of are followed, down to the one that is `Union{}` (or abstract) there, and said.

"""
    InferenceError

An entry point that does not infer to a concrete type, with the calls in the program that it comes from.
"""
struct InferenceError <: Exception
    call::String
    rt::Any
    path::Vector{String}  # the calls, from the entry point to where the type was lost
    notes::Vector{String} # what is wrong with the arguments of that call
end

function Base.showerror(io::IO, e::InferenceError)
    println(io, "InferenceError: ", e.call, " does not infer to a concrete type: it is `", e.rt, "`")
    if e.rt === Union{}
        println(io, "\nThat means that the compiler found that it can only throw, or that it calls something that no method fits the arguments of.")
    else
        println(io, "\nThe type of the result is not known when compiling, so the compiled code could not say what it returns.")
    end
    if !isempty(e.path)
        println(io, "\nThe calls that it comes from, from the entry point:")
        for (i, line) in enumerate(e.path)
            println(io, "  " ^ i, line)
        end
    end
    for note in e.notes
        println(io, "\n", note)
    end
    print(io, "\nHints: a type that is only known when the program runs (`Val(n)`, `SVector{n}`, a `Vector` where a `Tuple` or `SVector` is meant) is the usual cause; ",
              "give it as a constant, or in the type of an argument. `strict = false` does not help here: the return type has to be concrete.")
end

# the global variable that is not `const` that an argument is (read directly, or by a statement before), or `nothing`
function nonconst_global(ci::Core.CodeInfo, a)
    a isa Core.SSAValue && a.id <= length(ci.code) && (a = ci.code[a.id])
    return a isa GlobalRef && isdefined(a.mod, a.name) && !isconst(a.mod, a.name) ? a : nothing
end

function type_of_argument(ci::Core.CodeInfo, a)
    a isa Core.SSAValue && return CC.widenconst(ci.ssavaluetypes[a.id])
    a isa Core.Argument && return CC.widenconst(ci.slottypes[a.n])
    # (the type of a global that is not `const` is not known: it is whatever it is when the program runs)
    a isa GlobalRef && return isdefined(a.mod, a.name) ? (isconst(a.mod, a.name) ? Core.Typeof(getglobal(a.mod, a.name)) : Any) : Any
    a isa QuoteNode && return Core.Typeof(a.value)
    return Core.Typeof(a)
end

function callee_name(ci::Core.CodeInfo, f)
    f isa GlobalRef && return string(f.name)
    # (Julia 1.14 refers to a global by its binding: `BindingPartition(for Base.throw: ...)`)
    if nameof(typeof(f)) === :BindingPartition
        m = match(r"for ([\w.!]+?):", string(f))
        m === nothing || return last(split(m.captures[1], '.'))
    end
    f isa QuoteNode && return string(f.value)
    if f isa Core.SSAValue || f isa Core.Argument
        T = type_of_argument(ci, f)
        return T isa DataType && Base.issingletontype(T) ? string(T.instance) : string(T)
    end
    return string(f)
end

method_instance(x::Core.MethodInstance) = x
method_instance(x::Core.CodeInstance) = x.def isa Core.MethodInstance ? x.def : nothing
method_instance(x) = nothing

# the calls, inside the code of `f(types...)`, that have the type `Union{}` (what makes it that), as lines to say; and what is wrong with
# the arguments of the last one
function explain_inference!(path::Vector{String}, notes::Vector{String}, f, tt::Type, seen::Set; depth::Int = 0, kwargs...)
    depth > 8 && return false
    ci = try
        first(only(StaticCompiler.static_code_typed(f, tt; kwargs...)))
    catch
        return false
    end
    for (i, st) in enumerate(ci.code)
        T = ci.ssavaluetypes isa Vector ? ci.ssavaluetypes[i] : Any
        T === Union{} || continue
        st isa Expr && st.head in (:call, :invoke) || continue
        if st.head === :invoke
            mi = method_instance(st.args[1])
            if mi !== nothing && mi.specTypes isa DataType && (mi in seen) == false
                push!(seen, mi)
                spec = mi.specTypes
                ft = spec.parameters[1]
                g = Base.issingletontype(ft) ? ft.instance : nothing
                args = Tuple{spec.parameters[2:end]...}
                line = string(mi.def isa Method ? mi.def.name : callee_name(ci, st.args[2]), "(", join(("::" * string(p) for p in spec.parameters[2:end]), ", "), ")")
                push!(path, line)
                found = g !== nothing && isconcretetype(args) && explain_inference!(path, notes, g, args, seen; depth = depth + 1, kwargs...)
                found || push!(notes, string("The call `", line, "` always throws, as far as the compiler can tell (it ends in `throw`, or in a call that has no method)."))
                return true
            end
        else
            argtypes = [type_of_argument(ci, a) for a in st.args[2:end]]
            line = string(callee_name(ci, st.args[1]), "(", join(("::" * string(T) for T in argtypes), ", "), ")")
            callee = st.args[1]
            callee_type = callee isa Core.SSAValue || callee isa Core.Argument ? type_of_argument(ci, callee) : nothing
            callee_builtin = callee_name(ci, callee) == "throw"
            callee_builtin && continue # (a `throw` is the end of a path that throws: the call before it is what is looked for)
            push!(path, line)
            for a in st.args[2:end]
                g = nonconst_global(ci, a)
                g === nothing || push!(notes, string("`", g.mod, ".", g.name, "` is a global variable that is not `const` and has no declared type, so its type is not known when compiling (it can ",
                                                     "hold any type when the program runs). Make it `const` (a `Ref` or a container in a `const` can still be changed), or give it a type: `",
                                                     g.name, "::T = ...`."))
            end
            abstract = [T for T in argtypes if !isconcretetype(T) && !(T isa Union && all(isconcretetype, Base.uniontypes(T)))]
            if !isempty(abstract)
                push!(notes, string("The call `", line, "` has arguments whose types are not concrete (", join(unique(string.(abstract)), ", "),
                                   "), so no method could be chosen when compiling: its result is `Union{}` for the compiler, whatever it does when the program runs."))
            else
                push!(notes, string("The call `", line, "` is the last in the program that the compiler found to be `Union{}`: it throws, or no method of it fits those argument types."))
            end
            return true
        end
    end
    return false
end

# Check that the entry point `f(types...)` infers to a concrete type, and say where it does not if it doesn't
function check_entry(f, types; kwargs...)
    tt = try Base.to_tuple_type(types) catch; return end
    isconcretetype(tt) || return # (StaticCompiler says that)
    rt = try last(only(StaticCompiler.static_code_typed(f, tt; kwargs...))) catch; return end
    isconcretetype(rt) && return
    path, notes = String[], String[]
    explain_inference!(path, notes, f, tt, Set(); kwargs...)
    throw(InferenceError(string(nameof(f), "(", join(("::" * string(T) for T in tt.parameters), ", "), ")"), rt, path, notes))
end
