# A minimal, libjulia-free runtime for statically compiled code, which is installed in the code
# that StaticCompiler generates by `link_runtime!` (see `llvm_postprocess` in `overrides.jl`).
#
# GPUCompiler lowers most of the Julia runtime interface to a small set of hooks
# (`gpu_gc_pool_alloc`, ...), but StaticCompiler compiles with `libraries=false`, so nothing
# defines them, and some other intrinsics (GC frames, `jl_alloc_genericmemory_unchecked`, ...)
# are left untouched. We define all of those here, so that code which allocates (`Vector`,
# `Dict`, `String`, boxes, closures, ...) links to a standalone binary.
#
# Policy: there is no garbage collector. Allocation is `malloc`/`calloc` and memory is never
# freed unless the program manages it itself (see `StaticTools.MallocArray`, Bumper, ...).

module Runtime

using LLVM: LLVM, @dispose, run!
using LLVM.Passes: GlobalDCEPass
using StaticCompiler: isinttoptr, constant_address # from the pointer check

export link_runtime!, UnsupportedCodeError

const RUNTIME_SHIM_IR = raw"""
declare ptr @malloc(i64)
declare ptr @calloc(i64, i64)
declare i32 @puts(ptr)
declare void @exit(i32)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)
declare void @llvm.memmove.p0.p0.i64(ptr, ptr, i64, i1)

@_static_oom_msg = private unnamed_addr constant [20 x i8] c"Out of memory error\00"
; a zeroed dummy task: `julia.get_pgcstack` points into the middle of it, since compiled code
; addresses the task and its fields relative to that pointer
@_static_task = internal global [128 x i64] zeroinitializer, align 16

define internal void @_static_oom() noreturn {
  %s = call i32 @puts(ptr @_static_oom_msg)
  call void @exit(i32 1)
  unreachable
}

; objects: no GC, no type-tag header
define linkonce_odr ptr @gpu_gc_pool_alloc(i64 %sz) {
  %p = call ptr @calloc(i64 1, i64 %sz)
  %isnull = icmp eq ptr %p, null
  br i1 %isnull, label %oom, label %ok
oom:
  call void @_static_oom()
  unreachable
ok:
  ret ptr %p
}

; Julia 1.14: allocation of an object of a known size (the caller initializes the header)
define linkonce_odr ptr @"julia.gc_alloc_bytes"(ptr %ptls, i64 %sz, i64 %ty) {
  %p = call ptr @gpu_gc_pool_alloc(i64 %sz)
  ret ptr %p
}

; non-isbits allocations are permitted (and leaked) rather than flagged
define linkonce_odr void @gpu_unsupported_allocation(ptr %name) {
  ret void
}

; Memory{T} (Julia 1.11+): { length, data pointer } header followed by inline data.
; The caller fills in the length. Zeroed, as Julia does for pointer-containing memory.
define linkonce_odr ptr @jl_alloc_genericmemory_unchecked(ptr %ptls, i64 %nbytes, ptr %ty) {
  %total = add i64 %nbytes, 16
  %p = call ptr @calloc(i64 1, i64 %total)
  %isnull = icmp eq ptr %p, null
  br i1 %isnull, label %oom, label %ok
oom:
  call void @_static_oom()
  unreachable
ok:
  %data = getelementptr inbounds i8, ptr %p, i64 16
  %slot = getelementptr inbounds i8, ptr %p, i64 8
  store ptr %data, ptr %slot, align 8
  ret ptr %p
}

define linkonce_odr void @jl_argument_error(ptr %msg) noreturn {
  %s = call i32 @puts(ptr %msg)
  call void @exit(i32 1)
  unreachable
}

; boxed primitives (no type-tag header: only usable where the type is statically known,
; e.g. as arguments to the aborting error functions below)
define linkonce_odr ptr @ijl_box_int64(i64 %v) {
  %p = call ptr @gpu_gc_pool_alloc(i64 8)
  store i64 %v, ptr %p, align 8
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_uint64(i64 %v) {
  %p = call ptr @gpu_gc_pool_alloc(i64 8)
  store i64 %v, ptr %p, align 8
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_int32(i32 %v) {
  %p = call ptr @gpu_gc_pool_alloc(i64 8)
  store i32 %v, ptr %p, align 4
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_uint32(i32 %v) {
  %p = call ptr @gpu_gc_pool_alloc(i64 8)
  store i32 %v, ptr %p, align 4
  ret ptr %p
}

; String (Julia 1.11+): { length, data..., NUL }
define linkonce_odr ptr @ijl_alloc_string(i64 %n) {
  %total = add i64 %n, 9
  %p = call ptr @gpu_gc_pool_alloc(i64 %total)
  store i64 %n, ptr %p, align 8
  ret ptr %p
}

; a String with a copy of `n` bytes at `p`
define linkonce_odr ptr @ijl_pchar_to_string(ptr %p, i64 %n) {
  %s = call ptr @ijl_alloc_string(i64 %n)
  %d = getelementptr inbounds i8, ptr %s, i64 8
  call void @llvm.memcpy.p0.p0.i64(ptr %d, ptr %p, i64 %n, i1 false)
  ret ptr %s
}

define linkonce_odr ptr @jl_pchar_to_string(ptr %p, i64 %n) {
  %s = call ptr @ijl_pchar_to_string(ptr %p, i64 %n)
  ret ptr %s
}

; a Memory{UInt8} aliasing the data of a String
define linkonce_odr ptr @jl_string_to_genericmemory(ptr %s) {
  %m = call ptr @gpu_gc_pool_alloc(i64 16)
  %len = load i64, ptr %s, align 8
  store i64 %len, ptr %m, align 8
  %d = getelementptr inbounds i8, ptr %s, i64 8
  %slot = getelementptr inbounds i8, ptr %m, i64 8
  store ptr %d, ptr %slot, align 8
  ret ptr %m
}

; a String with the first %n bytes of a Memory{UInt8}
define linkonce_odr ptr @jl_genericmemory_to_string(ptr %m, i64 %n) {
  %s = call ptr @ijl_alloc_string(i64 %n)
  %sd = getelementptr inbounds i8, ptr %s, i64 8
  %slot = getelementptr inbounds i8, ptr %m, i64 8
  %src = load ptr, ptr %slot, align 8
  call void @llvm.memcpy.p0.p0.i64(ptr %sd, ptr %src, i64 %n, i1 false)
  ret ptr %s
}

; only reached for non-isbits element types, i.e. boxed (pointer-sized) elements
define linkonce_odr void @jl_genericmemory_copyto(ptr %dm, ptr %dd, ptr %sm, ptr %sd, i64 %n) {
  %bytes = mul i64 %n, 8
  call void @llvm.memmove.p0.p0.i64(ptr %dd, ptr %sd, i64 %bytes, i1 false)
  ret void
}

; there are no tasks: hand out a zeroed dummy task/ptls
define linkonce_odr ptr @"julia.get_pgcstack"() {
  ret ptr getelementptr inbounds (i8, ptr @_static_task, i64 512)
}

define linkonce_odr void @"julia.safepoint"(ptr %p) {
  ret void
}

define linkonce_odr void @"julia.cancellation_point"() {
  ret void
}

define linkonce_odr ptr @"julia.get_pgcstack_or_new"() {
  %p = call ptr @"julia.get_pgcstack"()
  ret ptr %p
}

; ---- exceptions ----
; `try` pushes a handler (a buffer for `sigsetjmp`, owned by the caller) and `throw` jumps to the
; innermost one. As in Julia, the catching code pops the handler itself. Exceptions are kept on
; a stack, which `catch` blocks restore on exit.
@_static_handlers = internal global [256 x ptr] zeroinitializer, align 16
@_static_nhandlers = internal global i64 0
@_static_excstack = internal global [256 x ptr] zeroinitializer, align 16
@_static_nexc = internal global i64 0
@_static_uncaught_msg = private unnamed_addr constant [51 x i8] c"fatal: uncaught exception (no handler to catch it)\00"
@_static_overflow_msg = private unnamed_addr constant [40 x i8] c"fatal: exception handler stack overflow\00"
@_static_nocurrent_msg = private unnamed_addr constant [31 x i8] c"fatal: rethrow() outside catch\00"

declare void @siglongjmp(ptr, i32) noreturn

define internal void @_static_fatal(ptr %msg) noreturn {
  %s = call i32 @puts(ptr %msg)
  call void @exit(i32 1)
  unreachable
}

define linkonce_odr void @ijl_enter_handler(ptr %task, ptr %h) {
  %n = load i64, ptr @_static_nhandlers, align 8
  %full = icmp uge i64 %n, 256
  br i1 %full, label %over, label %ok
over:
  call void @_static_fatal(ptr @_static_overflow_msg)
  unreachable
ok:
  %slot = getelementptr inbounds ptr, ptr @_static_handlers, i64 %n
  store ptr %h, ptr %slot, align 8
  %n1 = add i64 %n, 1
  store i64 %n1, ptr @_static_nhandlers, align 8
  ret void
}

define linkonce_odr void @ijl_pop_handler(ptr %task, i32 %k) {
  %n = load i64, ptr @_static_nhandlers, align 8
  %k64 = zext i32 %k to i64
  %m = sub i64 %n, %k64
  store i64 %m, ptr @_static_nhandlers, align 8
  ret void
}

define linkonce_odr void @ijl_pop_handler_noexcept(ptr %task, i32 %k) {
  call void @ijl_pop_handler(ptr %task, i32 %k)
  ret void
}

define linkonce_odr i64 @ijl_excstack_state(ptr %task) {
  %n = load i64, ptr @_static_nexc, align 8
  ret i64 %n
}

define linkonce_odr void @ijl_restore_excstack(ptr %task, i64 %state) {
  store i64 %state, ptr @_static_nexc, align 8
  ret void
}

define linkonce_odr void @ijl_throw(ptr %exc) noreturn {
  %ne = load i64, ptr @_static_nexc, align 8
  %efull = icmp uge i64 %ne, 256
  br i1 %efull, label %over, label %push
over:
  call void @_static_fatal(ptr @_static_overflow_msg)
  unreachable
push:
  %eslot = getelementptr inbounds ptr, ptr @_static_excstack, i64 %ne
  store ptr %exc, ptr %eslot, align 8
  %ne1 = add i64 %ne, 1
  store i64 %ne1, ptr @_static_nexc, align 8
  %n = load i64, ptr @_static_nhandlers, align 8
  %none = icmp eq i64 %n, 0
  br i1 %none, label %uncaught, label %jump
uncaught:
  call void @_static_fatal(ptr @_static_uncaught_msg)
  unreachable
jump:
  %i = sub i64 %n, 1
  %hslot = getelementptr inbounds ptr, ptr @_static_handlers, i64 %i
  %h = load ptr, ptr %hslot, align 8
  call void @siglongjmp(ptr %h, i32 1)
  unreachable
}

define linkonce_odr void @ijl_rethrow_other(ptr %exc) noreturn {
  call void @ijl_throw(ptr %exc)
  unreachable
}

define linkonce_odr ptr @ijl_current_exception(ptr %task) {
  %n = load i64, ptr @_static_nexc, align 8
  %none = icmp eq i64 %n, 0
  br i1 %none, label %null, label %get
null:
  ret ptr null
get:
  %i = sub i64 %n, 1
  %slot = getelementptr inbounds ptr, ptr @_static_excstack, i64 %i
  %e = load ptr, ptr %slot, align 8
  ret ptr %e
}

define linkonce_odr ptr @jl_current_exception(ptr %task) {
  %e = call ptr @ijl_current_exception(ptr %task)
  ret ptr %e
}

define linkonce_odr void @ijl_rethrow() noreturn {
  %n = load i64, ptr @_static_nexc, align 8
  %none = icmp eq i64 %n, 0
  br i1 %none, label %bad, label %go
bad:
  call void @_static_fatal(ptr @_static_nocurrent_msg)
  unreachable
go:
  %i = sub i64 %n, 1
  %slot = getelementptr inbounds ptr, ptr @_static_excstack, i64 %i
  %e = load ptr, ptr %slot, align 8
  store i64 %i, ptr @_static_nexc, align 8
  call void @ijl_throw(ptr %e)
  unreachable
}
"""

# the runtime functions defined by `RUNTIME_SHIM_IR`, which override declarations in `mod`
const RUNTIME_SHIM_FUNCTIONS = (
    "gpu_gc_pool_alloc", "gpu_unsupported_allocation", "jl_alloc_genericmemory_unchecked",
    "jl_argument_error", "julia.get_pgcstack", "julia.gc_alloc_bytes", "julia.safepoint", "julia.cancellation_point", "julia.get_pgcstack_or_new",
    "ijl_enter_handler", "ijl_pop_handler", "ijl_pop_handler_noexcept", "ijl_excstack_state",
    "ijl_restore_excstack", "ijl_throw", "ijl_rethrow", "ijl_rethrow_other",
    "ijl_current_exception", "jl_current_exception",
    "ijl_box_int64", "ijl_box_uint64", "ijl_box_int32", "ijl_box_uint32",
    "ijl_alloc_string", "ijl_pchar_to_string", "jl_pchar_to_string", "jl_string_to_genericmemory", "jl_genericmemory_to_string",
    "jl_genericmemory_copyto",
)

# The text of a constant C string global, or `nothing`
function constant_cstring(g)
    g isa LLVM.GlobalVariable || return nothing
    init = LLVM.initializer(g)
    init isa LLVM.ConstantDataArray || return nothing
    bytes = UInt8[convert(Int, e) for e in init.elements]
    return String(bytes[1:something(findfirst(==(0x00), bytes), length(bytes) + 1) - 1])
end

# Julia binds `ccall`s into libjulia lazily, through `ijl_load_and_lookup(lib, name, handle)`.
# For the symbols the runtime shim implements, resolve the lookup statically instead.
function resolve_lazy_lookups!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "ijl_load_and_lookup") || return false
    changed = false
    for use in collect(LLVM.uses(fns["ijl_load_and_lookup"]))
        call = LLVM.user(use)::LLVM.CallInst
        name = constant_cstring(LLVM.operands(call)[2])
        name in RUNTIME_SHIM_FUNCTIONS || continue
        target = haskey(fns, name) ? fns[name] :
                 LLVM.Function(mod, name, LLVM.FunctionType(LLVM.VoidType()))
        LLVM.replace_uses!(call, target)
        LLVM.erase!(call)
        changed = true
    end
    return changed
end

# Runtime functions that throw. Without unwinding, the best we can do is to report and exit.
# Their bodies are generated from the declaration, since we don't care about the arguments.
const ABORTING_RUNTIME_FUNCTIONS = (
    "ijl_bounds_error_int" => "BoundsError: index out of bounds",
    "ijl_bounds_error_unboxed_int" => "BoundsError: index out of bounds",
    "ijl_bounds_error" => "BoundsError: index out of bounds",
    "ijl_type_error" => "TypeError: type assertion failed",
    "ijl_undefined_var_error" => "UndefVarError: undefined variable",
    "jl_f_throw_methoderror" => "MethodError: no matching method",
)

# Runtime functions for dynamic behavior (dispatch on types only known at run time, ...), which
# a standalone binary can't provide. Code that calls them is rejected (`UnsupportedCodeError`)
# unless compiled with `strict = false`; they are then defined to abort if one is reached, which is
# often fine, as they typically sit on cold paths, e.g. building the message of an error.
const DYNAMIC_RUNTIME_FUNCTIONS = [
    name => "Dynamic behavior is not supported in standalone binaries ($name)" for name in (
        "ijl_apply_generic", "jl_apply_generic", "jl_f__apply_iterate", "jl_f_apply_type",
        "ijl_get_nth_field_checked", "jl_f_fieldtype", "jl_f_tuple", "ijl_new_structv",
        "jl_f__task", "jl_f__svec_ref", "jl_egal__unboxed", "ijl_subtype",
        "jl_get_abi_converter", "ijl_load_and_lookup", "ijl_lazy_load_and_lookup", "jl_f_getfield",
        "jl_f_isa", "jl_f_typeassert", "jl_f_issubtype", "ijl_new_task",
    )
]

# Give the body `puts(msg); exit(1)` to the declaration `fn`
function define_aborting!(mod::LLVM.Module, fn::LLVM.Function, msg::AbstractString)
    fns = LLVM.functions(mod)
    ptrT = LLVM.PointerType()
    puts_t = LLVM.FunctionType(LLVM.Int32Type(), [ptrT])
    exit_t = LLVM.FunctionType(LLVM.VoidType(), [LLVM.Int32Type()])
    puts = haskey(fns, "puts") ? fns["puts"] : LLVM.Function(mod, "puts", puts_t)
    exit = haskey(fns, "exit") ? fns["exit"] : LLVM.Function(mod, "exit", exit_t)
    LLVM.linkage!(fn, LLVM.API.LLVMLinkOnceODRLinkage)
    @dispose builder=LLVM.IRBuilder() begin
        bb = LLVM.BasicBlock(fn, "entry")
        LLVM.position!(builder, LLVM.at_end(bb))
        str = LLVM.globalstring_ptr!(builder, msg)
        LLVM.call!(builder, puts_t, puts, [str])
        LLVM.call!(builder, exit_t, exit, [LLVM.ConstantInt(Int32(1))])
        LLVM.unreachable!(builder)
    end
    return
end

# the Julia function that an instruction belongs to, as a readable name
function function_of(inst::LLVM.Instruction)
    name = LLVM.name(LLVM.parent(LLVM.parent(inst)))
    name = replace(name, r"^julia_" => "", r"_\d+$" => "")
    return name
end

# Runtime functions for errors, which are reported by aborting. The bodies are generated from the
# declaration, since we don't care about the arguments.
function define_aborting_functions!(mod::LLVM.Module)
    changed = false
    fns = LLVM.functions(mod)
    for (name, msg) in ABORTING_RUNTIME_FUNCTIONS
        haskey(fns, name) && LLVM.isdeclaration(fns[name]) || continue
        define_aborting!(mod, fns[name], msg)
        changed = true
    end
    return changed
end

"""
    UnsupportedCodeError

The code that was compiled contains things that cannot work in a standalone binary: calls that
need the Julia runtime (such as dynamic dispatch), or references to Julia objects by address. They
would crash the program, or abort it if they are reached. Compile with `strict = false` to
allow these (see `compile_executable`), or `allow = (...)` to allow specific runtime functions.
"""
struct UnsupportedCodeError <: Exception
    dynamic::Vector{Pair{String,Vector{String}}} # runtime function => where it is called from
    pointers::Vector{Tuple{String,String}}       # (function, instruction) that use an address
end

function Base.showerror(io::IO, e::UnsupportedCodeError)
    print(io, "UnsupportedCodeError: the code cannot run as a standalone binary")
    if !isempty(e.dynamic)
        print(io, "\n\nIt needs the Julia runtime (e.g. for dynamic dispatch, which means that the types in some call are not known at compile time):")
        for (name, callers) in e.dynamic
            print(io, "\n  ", name, ", called from ", join(first(callers, 5), ", "), length(callers) > 5 ? ", ..." : "")
        end
    end
    if !isempty(e.pointers)
        print(io, "\n\nIt refers to Julia objects by their address in this process, which are not in the binary:")
        for (fn, inst) in first(e.pointers, 5)
            print(io, "\n  in ", fn, ": ", strip(inst))
        end
        length(e.pointers) > 5 && print(io, "\n  ... and ", length(e.pointers) - 5, " more")
    end
    print(io, "\n\nPass `strict = false` to compile it anyway: calls that need the runtime will then abort the program if they are reached, and the addresses will crash it.")
    print(io, " Use `allow = (\"function_name\", ...)` to allow specific runtime functions only.")
end

# The calls (and the functions they are in) to the runtime functions that need dynamic behavior,
# which a standalone binary cannot provide. These are the declarations in `mod` that are used.
function dynamic_runtime_calls(mod::LLVM.Module; allow = ())
    found = Pair{String,Vector{String}}[]
    fns = LLVM.functions(mod)
    for (name, _) in DYNAMIC_RUNTIME_FUNCTIONS
        haskey(fns, name) && LLVM.isdeclaration(fns[name]) || continue
        name in allow && continue
        callers = String[]
        for use in LLVM.uses(fns[name])
            inst = LLVM.user(use)
            inst isa LLVM.Instruction || continue
            what = function_of(inst)
            # a `ccall` into a library that we couldn't resolve: say which function
            if inst isa LLVM.CallInst && name in ("ijl_load_and_lookup", "ijl_lazy_load_and_lookup")
                sym = constant_cstring(LLVM.operands(inst)[2])
                sym === nothing || (what = "$what (ccall to `$sym`)")
            end
            what in callers || push!(callers, what)
        end
        isempty(callers) || push!(found, name => callers)
    end
    return found
end

# Define the runtime functions for dynamic behavior as ones that abort, as the ones that are
# still used, which is what happens if `strict = false`.
function define_dynamic_stubs!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    for (name, msg) in DYNAMIC_RUNTIME_FUNCTIONS
        haskey(fns, name) && LLVM.isdeclaration(fns[name]) || continue
        isempty(LLVM.uses(fns[name])) && continue
        @debug "Code calls a runtime function that is not supported, and will abort if it is reached" name
        define_aborting!(mod, fns[name], msg)
    end
end

# The places where code reads, writes or calls through a pointer to a Julia object that is not
# in the binary (an address from this process): these are certain to crash. Passing such a
# pointer on as an argument, or comparing it, is common (type tags) and fine.
function unresolved_pointer_uses(mod::LLVM.Module)
    found = Tuple{String,String}[]
    seen = Set{Tuple{String,UInt}}()
    for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
        ops = if inst isa LLVM.LoadInst
            (LLVM.operands(inst)[1],)
        elseif inst isa LLVM.StoreInst
            Tuple(LLVM.operands(inst)[1:2])
        elseif inst isa LLVM.CallInst
            (LLVM.called_operand(inst),)
        elseif inst isa LLVM.GetElementPtrInst
            (LLVM.operands(inst)[1],)
        else
            ()
        end
        for op in ops
            op isa LLVM.ConstantExpr && isinttoptr(op) || continue
            addr = constant_address(op)
            (addr === nothing || addr < 0x10000) && continue
            key = (LLVM.name(fn), UInt(addr))
            key in seen && continue
            push!(seen, key)
            push!(found, (function_of(inst), string(inst)))
        end
    end
    return found
end

# Replace Julia's GC frame intrinsics (which have no runtime without a GC) by plain stack slots.
function lower_gc_frames!(mod::LLVM.Module)
    haskey(LLVM.functions(mod), "julia.new_gc_frame") || return false
    changed = false
    ptrT = LLVM.PointerType()
    @dispose builder=LLVM.IRBuilder() begin
        # slots first (they use the frame), then the frame itself
        if haskey(LLVM.functions(mod), "julia.get_gc_frame_slot")
            f = LLVM.functions(mod)["julia.get_gc_frame_slot"]
            for use in collect(LLVM.uses(f))
                call = LLVM.user(use)::LLVM.CallInst
                frame, idx = LLVM.operands(call)[1], LLVM.operands(call)[2]
                LLVM.position!(builder, LLVM.before(call))
                slot = LLVM.gep!(builder, ptrT, frame, [idx])
                LLVM.replace_uses!(call, slot)
                LLVM.erase!(call)
                changed = true
            end
        end
        for name in ("julia.push_gc_frame", "julia.pop_gc_frame")
            haskey(LLVM.functions(mod), name) || continue
            for use in collect(LLVM.uses(LLVM.functions(mod)[name]))
                LLVM.erase!(LLVM.user(use)::LLVM.CallInst)
                changed = true
            end
        end
        f = LLVM.functions(mod)["julia.new_gc_frame"]
        for use in collect(LLVM.uses(f))
            call = LLVM.user(use)::LLVM.CallInst
            n = LLVM.operands(call)[1]
            LLVM.position!(builder, LLVM.before(call))
            frame = LLVM.array_alloca!(builder, ptrT, n, "gcframe")
            # zero it, as a GC frame would expect
            sz = LLVM.mul!(builder, LLVM.zext!(builder, n, LLVM.Int64Type()), LLVM.ConstantInt(Int64(sizeof(Ptr))))
            LLVM.call!(builder, LLVM.FunctionType(LLVM.VoidType(), [ptrT, LLVM.Int8Type(), LLVM.Int64Type(), LLVM.Int1Type()]),
                  LLVM.Function(mod, "llvm.memset.p0.i64", LLVM.FunctionType(LLVM.VoidType(), [ptrT, LLVM.Int8Type(), LLVM.Int64Type(), LLVM.Int1Type()])),
                  [frame, LLVM.ConstantInt(UInt8(0)), sz, LLVM.ConstantInt(LLVM.Int1Type(), 0)])
            LLVM.replace_uses!(call, frame)
            LLVM.erase!(call)
            changed = true
        end
    end
    return changed
end

# `jl_small_typeof` is a table of the type objects of the most common types, indexed by their
# (small) type tag, which compiled code reads when it needs the type of an object it allocates.
# There are no type objects in a standalone binary, so the entries only serve as distinct,
# non-null tokens that identify the type.
function define_small_typeof!(mod::LLVM.Module)
    globals = LLVM.globals(mod)
    haskey(globals, "jl_small_typeof") || return false
    old = globals["jl_small_typeof"]
    LLVM.isdeclaration(old) || return false
    n = (64 << 4) ÷ sizeof(Ptr)
    ptrT = LLVM.PointerType()
    entries = [LLVM.const_inttoptr(LLVM.ConstantInt(Int64(16i)), ptrT) for i in 1:n]
    init = LLVM.ConstantArray(ptrT, entries)
    LLVM.name!(old, "jl_small_typeof.declaration")
    new = LLVM.GlobalVariable(mod, LLVM.ArrayType(ptrT, n), "jl_small_typeof")
    LLVM.initializer!(new, init)
    LLVM.constant!(new, true)
    LLVM.linkage!(new, LLVM.API.LLVMLinkOnceODRLinkage)
    LLVM.replace_uses!(old, new)
    LLVM.erase!(old)
    return true
end

# Globals of the Julia runtime that hold a pointer to a well-known object (compiled code loads
# the pointer from the global). We make each point to a copy of the object in the binary.
const WELL_KNOWN_OBJECTS = (
    "jl_nothing" => nothing, "jl_emptytuple" => (), "jl_true" => true, "jl_false" => false,
    "jl_diverror_exception" => DivideError(), "jl_undefref_exception" => UndefRefError(),
    "jl_memory_exception" => OutOfMemoryError(), "jl_stackovf_exception" => StackOverflowError(),
    "jl_readonlymemory_exception" => ReadOnlyMemoryError(), "jl_interrupt_exception" => InterruptException(),
)

function define_well_known_objects!(mod::LLVM.Module)
    changed = false
    for (name, obj) in WELL_KNOWN_OBJECTS
        globals = LLVM.globals(mod)
        haskey(globals, name) && LLVM.isdeclaration(globals[name]) || continue
        old = globals[name]
        # the object, preceded by its type tag as it is in this process
        addr = UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), obj))
        tag = unsafe_load(Ptr{UInt}(addr - 8))
        n = max(sizeof(typeof(obj)), 8) # room for at least a word, so that the address is a valid one
        payload = zeros(UInt8, n)
        sizeof(typeof(obj)) > 0 && unsafe_copyto!(pointer(payload), Ptr{UInt8}(addr), sizeof(typeof(obj)))
        st = LLVM.StructType([LLVM.Int64Type(), LLVM.ArrayType(LLVM.Int8Type(), n)]; packed = true)
        object = LLVM.GlobalVariable(mod, st, "static_$name")
        LLVM.initializer!(object, LLVM.ConstantStruct([LLVM.ConstantInt(Int64(tag)), LLVM.ConstantDataArray(LLVM.Int8Type(), payload)]; packed = true))
        LLVM.linkage!(object, LLVM.API.LLVMLinkOnceODRLinkage)
        LLVM.alignment!(object, 16)
        ptrT = LLVM.PointerType()
        pointer_to_object = LLVM.const_gep(LLVM.Int8Type(), object, [LLVM.ConstantInt(Int64(8))])
        LLVM.name!(old, name * ".declaration")
        new = LLVM.GlobalVariable(mod, ptrT, name)
        LLVM.initializer!(new, pointer_to_object)
        LLVM.constant!(new, true)
        LLVM.linkage!(new, LLVM.API.LLVMLinkOnceODRLinkage)
        LLVM.replace_uses!(old, new)
        LLVM.erase!(old)
        changed = true
    end
    return changed
end

# Define the runtime functions that `mod` calls but does not define.
function link_runtime!(mod::LLVM.Module; strict::Bool = true, allow = ())
    define_small_typeof!(mod)
    define_well_known_objects!(mod)
    lower_gc_frames!(mod)
    embed_constants!(mod)
    resolve_lazy_lookups!(mod)
    define_aborting_functions!(mod)
    if strict
        dynamic = dynamic_runtime_calls(mod; allow)
        pointers = unresolved_pointer_uses(mod)
        isempty(dynamic) && isempty(pointers) || throw(UnsupportedCodeError(dynamic, pointers))
    end
    define_dynamic_stubs!(mod)
    needed = filter(RUNTIME_SHIM_FUNCTIONS) do name
        haskey(LLVM.functions(mod), name) && LLVM.isdeclaration(LLVM.functions(mod)[name])
    end
    isempty(needed) && return mod
    shim = parse(LLVM.Module, RUNTIME_SHIM_IR)
    LLVM.datalayout!(shim, LLVM.datalayout(mod))
    LLVM.triple!(shim, LLVM.triple(mod))
    LLVM.link!(mod, shim) # consumes `shim`
    run!(GlobalDCEPass(), mod)
    return mod
end

# ---------------------------------------------------------------------------------------
# Constants: compiled code refers to some Julia objects by address (`inttoptr`), which is
# meaningless in a standalone binary (string literals, `const` arrays and `Ref`s, the empty
# `Memory` singletons, ...). We copy the objects we can reproduce into globals of the module,
# following references to other objects, and point the code at those instead. Objects that
# contain things we can't reproduce (types, symbols, functions, ...) are left alone, to be
# reported by the pointer check.
#
# The globals have no type-tag header, since there is no type object to tag them with.

# A word of memory at `addr`, or `nothing` if it is not readable. The kernel checks the
# address when we ask it to copy the word into a pipe, so we don't crash on a bad pointer.
const PIPE_FDS = Cint[-1, -1]
function safe_load(addr::UInt)::Union{UInt,Nothing}
    PIPE_FDS[1] < 0 && (ccall(:pipe, Cint, (Ptr{Cint},), PIPE_FDS) == 0 || error("pipe failed"))
    n = ccall(:write, Cssize_t, (Cint, UInt, Csize_t), PIPE_FDS[2], addr, 8)
    n == 8 || return nothing
    out = Ref{UInt}(0)
    ccall(:read, Cssize_t, (Cint, Ptr{UInt}, Csize_t), PIPE_FDS[1], out, 8) == 8 || return nothing
    return out[]
end

# throw `EmbedFailure` unless the `n` bytes at `addr` can be read
function check_readable(addr::UInt, n::Integer)
    n >= 0 && n < (1 << 28) || throw(EmbedFailure())
    n == 0 && return
    for off in 0:4096:(n - 1)
        safe_load(addr + off) === nothing && throw(EmbedFailure())
    end
    safe_load(addr + max(n - 8, 0)) === nothing && throw(EmbedFailure())
    return
end

const DATATYPE_TAG = Ref{UInt}(0) # the tag of `DataType` objects

# the type of the Julia object at `addr`, from its type tag, or `nothing` if it doesn't look
# like an object.
function object_type(addr::UInt)
    # (all Julia objects are 16-byte aligned, which rules out many addresses that are not objects:
    # in particular the data of strings and arrays, which is 8 bytes after the start of the object)
    addr >= 0x10000 && addr % 16 == 0 || return nothing
    DATATYPE_TAG[] == 0 && (DATATYPE_TAG[] = unsafe_load(Ptr{UInt}(UInt(pointer_from_objref(typeof(Int))) - 8)) & ~UInt(15))
    word = safe_load(addr - 8)
    word === nothing && return nothing
    tag = word & ~UInt(15)
    ptr = if tag < (64 << 4)
        unsafe_load(cglobal(:jl_small_typeof, Ptr{Ptr{Cvoid}}), (tag >> 3) + 1)
    else
        Ptr{Cvoid}(tag)
    end
    ptr == C_NULL && return nothing
    # the tag must point at a `DataType`
    typetag = safe_load(UInt(ptr) - 8)
    (typetag === nothing || typetag & ~UInt(15) != DATATYPE_TAG[]) && return nothing
    T = unsafe_pointer_to_objref(ptr)
    return T isa DataType && isconcretetype(T) && !(T <: Type) ? T : nothing
end

mutable struct ObjectEmbedder
    mod::LLVM.Module
    globals::Dict{UInt,Union{LLVM.GlobalVariable,Nothing}} # object address => its global
end

struct EmbedFailure <: Exception end # an object we can't reproduce

const EMBED_ALIGN = 16

# `LLVM` constants for the pieces of a global, to be laid out contiguously (packed)
bytes_piece(addr, n) = n == 0 ? nothing :
    LLVM.ConstantDataArray(LLVM.Int8Type(), copy(unsafe_wrap(Array, Ptr{UInt8}(addr), n)))
nullptr() = LLVM.PointerNull(LLVM.PointerType())
i64(x) = LLVM.ConstantInt(Int64(x))

function embed_global!(e::ObjectEmbedder, addr::UInt)
    if haskey(e.globals, addr)
        g = e.globals[addr]
        g === nothing && throw(EmbedFailure())
        return g
    end
    e.globals[addr] = nothing # failed, or in progress
    T = object_type(addr)
    T === nothing && throw(EmbedFailure())
    # `values` needs the global, since objects may refer to themselves or to each other
    types, values = object_pieces(e, T, addr)
    st = LLVM.StructType(types; packed=true)
    g = LLVM.GlobalVariable(e.mod, st, "static_object_$(string(addr, base=16))")
    LLVM.linkage!(g, LLVM.API.LLVMPrivateLinkage)
    LLVM.alignment!(g, EMBED_ALIGN)
    e.globals[addr] = g
    try
        LLVM.initializer!(g, LLVM.ConstantStruct(values(g); packed=true))
    catch
        e.globals[addr] = nothing
        LLVM.initializer!(g, LLVM.null(st))
        rethrow()
    end
    return g
end

# a reference to the object at `addr` (or null), as an LLVM constant
function embed_ref!(e::ObjectEmbedder, addr::UInt, offset=0)
    addr == 0 && return nullptr()
    g = embed_global!(e, addr)
    return offset == 0 ? g : LLVM.const_gep(LLVM.Int8Type(), g, [i64(offset)])
end

function object_pieces(e::ObjectEmbedder, T::DataType, addr::UInt)
    if T === Symbol || T === Core.SimpleVector || T === Module
        throw(EmbedFailure()) # interned by the runtime
    elseif T === String
        check_readable(addr, 8)
        n = 8 + unsafe_load(Ptr{Int}(addr)) + 1
        check_readable(addr, n)
        return [LLVM.ArrayType(LLVM.Int8Type(), n)], g -> [bytes_piece(addr, n)]
    elseif T <: Core.GenericMemory
        return memory_pieces(e, T, addr)
    elseif fieldcount(T) > 0
        return struct_pieces(e, T, addr)
    end
    throw(EmbedFailure())
end

# { length, data pointer, data... } with the data inline, as for the memory Julia allocates
function memory_pieces(e::ObjectEmbedder, T, addr::UInt)
    ET = eltype(T)
    check_readable(addr, 16)
    len = unsafe_load(Ptr{Int}(addr))
    data = unsafe_load(Ptr{UInt}(addr + 8))
    ptrT = LLVM.PointerType()
    if isbitstype(ET) && Base.datatype_pointerfree(ET) # plain data
        n = len * Base.aligned_sizeof(ET)
        check_readable(data, n)
        types = LLVM.LLVMType[LLVM.Int64Type(), ptrT, LLVM.ArrayType(LLVM.Int8Type(), n)]
        return types, g -> LLVM.Constant[i64(len), LLVM.const_gep(LLVM.Int8Type(), g, [i64(16)]), something(bytes_piece(data, n), LLVM.null(types[3]))]
    elseif !isbitstype(ET) && !(ET isa Union) && Base.allocatedinline(ET) == false # boxed elements
        check_readable(data, 8 * len)
        refs = [unsafe_load(Ptr{UInt}(data + 8(i - 1))) for i in 1:len]
        types = LLVM.LLVMType[LLVM.Int64Type(), ptrT, (ptrT for _ in 1:len)...]
        return types, g -> LLVM.Constant[i64(len), LLVM.const_gep(LLVM.Int8Type(), g, [i64(16)]), (embed_ref!(e, r) for r in refs)...]
    end
    throw(EmbedFailure())
end

# the fields of a struct, in memory order, with padding copied as is
function struct_pieces(e::ObjectEmbedder, T::DataType, addr::UInt)
    types = LLVM.LLVMType[]
    thunks = Function[]
    function add!(t, thunk)
        push!(types, t); push!(thunks, thunk)
    end
    add_bytes!(from, n) = n > 0 && add!(LLVM.ArrayType(LLVM.Int8Type(), n), g -> bytes_piece(from, n))
    function add_fields!(T, base)
        pos = 0 # offset within T
        for i in 1:fieldcount(T)
            off, ft = fieldoffset(T, i), fieldtype(T, i)
            add_bytes!(base + pos, off - pos)
            if T <: Core.GenericMemoryRef && i == 1
                # a pointer into the data of the memory, which is the second field
                mem = unsafe_load(Ptr{UInt}(base + fieldoffset(T, 2)))
                check_readable(mem, 16)
                memdata = unsafe_load(Ptr{UInt}(mem + 8))
                p = unsafe_load(Ptr{UInt}(base + off))
                add!(LLVM.PointerType(), g -> embed_ref!(e, mem, 16 + Int(p) - Int(memdata)))
                pos = off + sizeof(Ptr)
            elseif T <: Core.GenericMemoryRef && i == 2
                mem = unsafe_load(Ptr{UInt}(base + off))
                add!(LLVM.PointerType(), g -> embed_ref!(e, mem))
                pos = off + sizeof(Ptr)
            elseif Base.allocatedinline(ft)
                if Base.datatype_pointerfree(ft)
                    add_bytes!(base + off, sizeof(ft))
                else
                    add_fields!(ft, base + off)
                end
                pos = off + sizeof(ft)
            else # reference to another object
                r = unsafe_load(Ptr{UInt}(base + off))
                add!(LLVM.PointerType(), g -> embed_ref!(e, r))
                pos = off + sizeof(Ptr)
            end
        end
        add_bytes!(base + pos, sizeof(T) - pos)
    end
    check_readable(addr, sizeof(T))
    add_fields!(T, addr)
    isempty(types) && throw(EmbedFailure())
    # values are created after the global, but the references they hold must exist before
    # it is (to compute the global's type), so they are created here and handed out later
    return types, g -> LLVM.Constant[thunk(g) for thunk in thunks]
end

# all `inttoptr (i64 N to ptr)` constants used by instructions of `mod`, by address
function inttoptr_constants(mod::LLVM.Module)
    consts = Dict{UInt,Vector{LLVM.Value}}()
    for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb), op in LLVM.operands(inst)
        op isa LLVM.ConstantExpr && isinttoptr(op) || continue
        addr = constant_address(op)
        (addr === nothing || addr < 0x10000) && continue
        push!(get!(Vector{LLVM.Value}, consts, UInt(addr)), op)
    end
    return consts
end

# The object that `addr` points into, with the offset of `addr` in it: constants can point
# at fields of an object (e.g., the data of a string)
function object_extent(T::DataType, base::UInt)
    T === String && return 8 + unsafe_load(Ptr{Int}(base)) + 1
    if T <: Core.GenericMemory
        ET = eltype(T)
        len = unsafe_load(Ptr{Int}(base))
        # the header and the elements, which are inline (and boxed elements are pointers)
        return 16 + len * (isbitstype(ET) ? Base.aligned_sizeof(ET) : sizeof(Ptr))
    end
    return try Core.sizeof(T) catch; 0 end # no definite size: not something we embed
end

# The objects that `addr` may point into, as (base address, offset of `addr` in it): constants can
# point at fields of an object (e.g., the data of a string). Whether there is an object at an
# address is judged by its type tag, the word before it, and an address that is not that of an
# object may look like one by chance. So there can be several candidates, only one of which is
# right, and the caller needs to try them in order: the one closest to `addr` first, since a
# false one is usually further away. (The false ones that are tried usually fail to be
# embedded: their contents are not valid.)
function find_objects(addr::UInt)
    candidates = Tuple{UInt,Int}[]
    for delta in 0:8:256
        base = addr - delta
        T = object_type(base)
        T === nothing && continue
        delta <= max(object_extent(T, base), 8) || continue
        push!(candidates, (base, delta))
    end
    return candidates
end

function embed_constants!(mod::LLVM.Module)
    consts = inttoptr_constants(mod)
    isempty(consts) && return false
    e = ObjectEmbedder(mod, Dict())
    changed = false
    for (addr, ops) in consts
        replacement = nothing
        for (base, delta) in find_objects(addr)
            # embedding may fail halfway, leaving globals behind that nothing refers to
            replacement = try
                embed_ref!(e, base, delta)
            catch err
                err isa EmbedFailure || @debug "Could not embed object" address=base type=object_type(base) exception=(err, catch_backtrace())
                nothing
            end
            replacement === nothing || break
        end
        replacement === nothing && continue
        for op in ops
            LLVM.replace_uses!(op, replacement)
        end
        changed = true
    end
    # drop the globals of objects that failed, and of objects only they referred to
    while true
        dead = [g for g in LLVM.globals(mod) if startswith(LLVM.name(g), "static_object_") && isempty(LLVM.uses(g))]
        isempty(dead) && break
        foreach(LLVM.erase!, dead)
    end
    return changed
end

end # module Runtime
