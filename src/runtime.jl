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

; Objects have a header of 16 bytes before them, as in Julia: the type tag, in the 8 bytes before the
; object (which compiled code may write: see `julia.gc_alloc_bytes` below), and padding, so that the
; object is aligned to 16 bytes. No GC: nothing is ever freed.
define linkonce_odr ptr @gpu_gc_pool_alloc(i64 %sz) {
  %total = add i64 %sz, 16
  %p = call ptr @calloc(i64 1, i64 %total)
  %isnull = icmp eq ptr %p, null
  br i1 %isnull, label %oom, label %ok
oom:
  call void @_static_oom()
  unreachable
ok:
  %obj = getelementptr inbounds i8, ptr %p, i64 16
  ret ptr %obj
}

; Julia 1.14: allocation of an object of a known size: the caller writes the type tag, at `obj - 8`
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
  %obj = call ptr @gpu_gc_pool_alloc(i64 %total)
  %tagslot = getelementptr inbounds i8, ptr %obj, i64 -8
  %tag = ptrtoint ptr %ty to i64
  store i64 %tag, ptr %tagslot, align 8
  %data = getelementptr inbounds i8, ptr %obj, i64 16
  %slot = getelementptr inbounds i8, ptr %obj, i64 8
  store ptr %data, ptr %slot, align 8
  ret ptr %obj
}

; `===` of two objects that are not the same one and are not compared inline, of the same type (`dtag` is its type
; tag): a `String`, a boxed number, and an immutable struct or tuple (egal to another with the same contents). The
; type of a struct says how to compare it in the memory before its `layout` (see `egal_plan`): a number of operations
; (negative for a mutable type, which is egal only to itself), each of 16 bytes: a kind (0: the bytes at an offset
; are the same, 1: the objects that the field at the offset refers to are egal, 2: not supported), the offset, and
; the number of bytes. Other objects (types, `svec`s, ...) are not supported: it reports and exits, rather than being wrong.
declare i32 @memcmp(ptr, ptr, i64)
@_static_egal_msg = private unnamed_addr constant [75 x i8] c"=== of objects of this type is not supported in standalone binaries (egal)\00"
define linkonce_odr i32 @jl_egal__unboxed(ptr %a, ptr %b, i64 %dtag0) {
entry:
  %same = icmp eq ptr %a, %b
  br i1 %same, label %yes, label %check
check:
  %dtag = and i64 %dtag0, -16
  %issymbol = icmp eq i64 %dtag, {{TAG_SYMBOL}}
  %isbool = icmp eq i64 %dtag, {{TAG_BOOL}}
  %isnothing = icmp eq i64 %dtag, {{TAG_NOTHING}}
  %singleton0 = or i1 %issymbol, %isbool
  %singleton = or i1 %singleton0, %isnothing
  br i1 %singleton, label %no, label %checkstring
checkstring:
  %isstring = icmp eq i64 %dtag, {{TAG_STRING}}
  br i1 %isstring, label %string, label %numbers
string:
  %la = load i64, ptr %a, align 8
  %lb = load i64, ptr %b, align 8
  %leq = icmp eq i64 %la, %lb
  br i1 %leq, label %compare, label %no
compare:
  %da = getelementptr inbounds i8, ptr %a, i64 8
  %db = getelementptr inbounds i8, ptr %b, i64 8
  %r = call i32 @memcmp(ptr %da, ptr %db, i64 %la)
  %zero = icmp eq i32 %r, 0
  %result = zext i1 %zero to i32
  ret i32 %result
numbers:
  %i8a = icmp eq i64 %dtag, {{TAG_INT8}}
  %i8b = icmp eq i64 %dtag, {{TAG_UINT8}}
  %i16a = icmp eq i64 %dtag, {{TAG_INT16}}
  %i16b = icmp eq i64 %dtag, {{TAG_UINT16}}
  %i32a = icmp eq i64 %dtag, {{TAG_INT32}}
  %i32b = icmp eq i64 %dtag, {{TAG_UINT32}}
  %i32c = icmp eq i64 %dtag, {{TAG_CHAR}}
  %i64a = icmp eq i64 %dtag, {{TAG_INT64}}
  %i64b = icmp eq i64 %dtag, {{TAG_UINT64}}
  %c1 = or i1 %i8a, %i8b
  %c2 = or i1 %i16a, %i16b
  %c4a = or i1 %i32a, %i32b
  %c4 = or i1 %c4a, %i32c
  %c8 = or i1 %i64a, %i64b
  %s8 = select i1 %c8, i64 8, i64 0
  %s4 = select i1 %c4, i64 4, i64 %s8
  %s2 = select i1 %c2, i64 2, i64 %s4
  %nbytes = select i1 %c1, i64 1, i64 %s2
  %isnumber = icmp ne i64 %nbytes, 0
  br i1 %isnumber, label %number, label %other
number:
  %nr = call i32 @memcmp(ptr %a, ptr %b, i64 %nbytes)
  %nz = icmp eq i32 %nr, 0
  %nresult = zext i1 %nz to i32
  ret i32 %nresult
other:
  %small = icmp ult i64 %dtag, 1024
  br i1 %small, label %unsupported, label %datatype
datatype:
  %dt = inttoptr i64 %dtag to ptr
  %lp = getelementptr inbounds i8, ptr %dt, i64 {{LAYOUT_OFFSET}}
  %layout = load ptr, ptr %lp, align 8
  %nolayout = icmp eq ptr %layout, null
  br i1 %nolayout, label %unsupported, label %plan
plan:
  %hp = getelementptr inbounds i8, ptr %layout, i64 -8
  %n = load i64, ptr %hp, align 8
  %mutable = icmp slt i64 %n, 0
  br i1 %mutable, label %no, label %plan_ops
plan_ops:
  %opbytes = shl i64 %n, 4
  %opoffset = sub i64 -8, %opbytes
  %ops = getelementptr inbounds i8, ptr %layout, i64 %opoffset
  br label %loop
loop:
  %i = phi i64 [ 0, %plan_ops ], [ %inext, %next ]
  %done = icmp eq i64 %i, %n
  br i1 %done, label %yes, label %op
op:
  %o = shl i64 %i, 4
  %opp = getelementptr inbounds i8, ptr %ops, i64 %o
  %kind = load i32, ptr %opp, align 4
  %offp = getelementptr inbounds i8, ptr %opp, i64 4
  %off32 = load i32, ptr %offp, align 4
  %off = zext i32 %off32 to i64
  %szp = getelementptr inbounds i8, ptr %opp, i64 8
  %sz32 = load i32, ptr %szp, align 4
  %sz = zext i32 %sz32 to i64
  %pa = getelementptr inbounds i8, ptr %a, i64 %off
  %pb = getelementptr inbounds i8, ptr %b, i64 %off
  %ismem = icmp eq i32 %kind, 0
  br i1 %ismem, label %memop, label %notmem
memop:
  %mr = call i32 @memcmp(ptr %pa, ptr %pb, i64 %sz)
  %meq = icmp eq i32 %mr, 0
  br i1 %meq, label %next, label %no
notmem:
  %isref = icmp eq i32 %kind, 1
  br i1 %isref, label %refop, label %unsupported
refop:
  %ra = load ptr, ptr %pa, align 8
  %rb = load ptr, ptr %pb, align 8
  %sameref = icmp eq ptr %ra, %rb
  br i1 %sameref, label %next, label %refs
refs:
  %anull = icmp eq ptr %ra, null
  %bnull = icmp eq ptr %rb, null
  %eithernull = or i1 %anull, %bnull
  br i1 %eithernull, label %no, label %reftags
reftags:
  %tpa = getelementptr inbounds i8, ptr %ra, i64 -8
  %tpb = getelementptr inbounds i8, ptr %rb, i64 -8
  %ta0 = load i64, ptr %tpa, align 8
  %tb0 = load i64, ptr %tpb, align 8
  %ta = and i64 %ta0, -16
  %tb = and i64 %tb0, -16
  %sametype = icmp eq i64 %ta, %tb
  br i1 %sametype, label %recurse, label %no
recurse:
  %rr = call i32 @jl_egal__unboxed(ptr %ra, ptr %rb, i64 %ta)
  %rok = icmp ne i32 %rr, 0
  br i1 %rok, label %next, label %no
next:
  %inext = add i64 %i, 1
  br label %loop
unsupported:
  %s = call i32 @puts(ptr @_static_egal_msg)
  call void @exit(i32 1)
  unreachable
yes:
  ret i32 1
no:
  ret i32 0
}

define linkonce_odr void @jl_argument_error(ptr %msg) noreturn {
  %s = call i32 @puts(ptr %msg)
  call void @exit(i32 1)
  unreachable
}

; boxed primitives
define linkonce_odr ptr @ijl_box_int64(i64 %v) {
  %p = call ptr @gpu_gc_pool_alloc(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_INT64}}, ptr %tagslot, align 8
  store i64 %v, ptr %p, align 8
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_uint64(i64 %v) {
  %p = call ptr @gpu_gc_pool_alloc(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_UINT64}}, ptr %tagslot, align 8
  store i64 %v, ptr %p, align 8
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_int32(i32 %v) {
  %p = call ptr @gpu_gc_pool_alloc(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_INT32}}, ptr %tagslot, align 8
  store i32 %v, ptr %p, align 4
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_uint32(i32 %v) {
  %p = call ptr @gpu_gc_pool_alloc(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_UINT32}}, ptr %tagslot, align 8
  store i32 %v, ptr %p, align 4
  ret ptr %p
}

; String (Julia 1.11+): { length, data..., NUL }
define linkonce_odr ptr @ijl_alloc_string(i64 %n) {
  %total = add i64 %n, 9
  %p = call ptr @gpu_gc_pool_alloc(i64 %total)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_STRING}}, ptr %tagslot, align 8
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

; a String with a copy of the C string at `p`
declare i64 @strlen(ptr)
define linkonce_odr ptr @ijl_cstr_to_string(ptr %p) {
  %n = call i64 @strlen(ptr %p)
  %s = call ptr @ijl_pchar_to_string(ptr %p, i64 %n)
  ret ptr %s
}

define linkonce_odr ptr @jl_cstr_to_string(ptr %p) {
  %s = call ptr @ijl_cstr_to_string(ptr %p)
  ret ptr %s
}

; a Memory{UInt8} aliasing the data of a String
define linkonce_odr ptr @jl_string_to_genericmemory(ptr %s) {
  %m = call ptr @gpu_gc_pool_alloc(i64 16)
  %tagslot = getelementptr inbounds i8, ptr %m, i64 -8
  store i64 {{TAG_MEMORY_UINT8}}, ptr %tagslot, align 8
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

# The type tag of the objects of a type, as Julia writes it before them (in this process, where the
# code that is compiled has been inferred, so the tags that it compares with are these as well)
object_tag(x) = Int64(unsafe_load(Ptr{UInt}(UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), x)) - 8)) & ~UInt(15))

# `RUNTIME_SHIM_IR`, with the type tags of the types of the objects that it makes
function shim_ir()
    ir = RUNTIME_SHIM_IR
    ir = replace(ir, "{{LAYOUT_OFFSET}}" => string(fieldoffset(DataType, findfirst(==(:layout), fieldnames(DataType)))))
    for (token, example) in ("TAG_STRING" => "", "TAG_INT64" => 1, "TAG_UINT64" => UInt64(1),
                             "TAG_INT32" => Int32(1), "TAG_UINT32" => UInt32(1),
                             "TAG_INT8" => Int8(1), "TAG_UINT8" => UInt8(1), "TAG_INT16" => Int16(1),
                             "TAG_UINT16" => UInt16(1), "TAG_CHAR" => 'a',
                             "TAG_SYMBOL" => :a, "TAG_BOOL" => true, "TAG_NOTHING" => nothing,
                             "TAG_MEMORY_UINT8" => Memory{UInt8}(undef, 1))
        ir = replace(ir, "{{$token}}" => string(object_tag(example)))
    end
    return ir
end

# the runtime functions defined by `RUNTIME_SHIM_IR`, which override declarations in `mod`
const RUNTIME_SHIM_FUNCTIONS = (
    "gpu_gc_pool_alloc", "gpu_unsupported_allocation", "jl_alloc_genericmemory_unchecked",
    "jl_argument_error", "jl_egal__unboxed", "julia.get_pgcstack", "julia.gc_alloc_bytes", "julia.safepoint", "julia.cancellation_point", "julia.get_pgcstack_or_new",
    "ijl_enter_handler", "ijl_pop_handler", "ijl_pop_handler_noexcept", "ijl_excstack_state",
    "ijl_restore_excstack", "ijl_throw", "ijl_rethrow", "ijl_rethrow_other",
    "ijl_current_exception", "jl_current_exception",
    "ijl_box_int64", "ijl_box_uint64", "ijl_box_int32", "ijl_box_uint32",
    "ijl_alloc_string", "ijl_pchar_to_string", "jl_pchar_to_string", "ijl_cstr_to_string", "jl_cstr_to_string", "jl_string_to_genericmemory", "jl_genericmemory_to_string",
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

# Functions of the C library and of the math library, which every executable links to: a `ccall` to
# these is a call to the function.
const LIBC_FUNCTIONS = Set([
    "strlen", "strnlen", "memcpy", "memmove", "memset", "memcmp", "memchr", "strcmp", "strncmp",
    "strchr", "strrchr", "strstr", "malloc", "calloc", "realloc", "free", "abort", "exit", "getenv",
    "atoi", "strtol", "strtoul", "strtoll", "strtoull", "strtod", "strtof", "qsort", "bsearch",
    "write", "read", "puts", "putchar", "getchar", "fflush", "fputc", "fputs", "fwrite", "fread",
    "usleep", "nanosleep", "clock_gettime", "time", "getentropy",
    # libm
    "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "asinh", "acosh",
    "atanh", "exp", "exp2", "expm1", "log", "log2", "log10", "log1p", "pow", "sqrt", "cbrt", "hypot",
    "fabs", "floor", "ceil", "trunc", "round", "rint", "nearbyint", "fmod", "remainder", "ldexp",
    "frexp", "modf", "erf", "erfc", "tgamma", "lgamma", "copysign", "fma", "fmin", "fmax",
    ("$(f)f" for f in ("sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "exp",
                       "exp2", "expm1", "log", "log2", "log10", "log1p", "pow", "sqrt", "cbrt", "hypot",
                       "fabs", "floor", "ceil", "trunc", "round", "rint", "fmod", "ldexp", "copysign"))...,
])

# Julia binds `ccall`s lazily, through `ijl_load_and_lookup(lib, name, handle)`. For the symbols the
# runtime shim implements, and those of the C library, resolve the lookup statically instead.
function resolve_lazy_lookups!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "ijl_load_and_lookup") || return false
    changed = false
    for use in collect(LLVM.uses(fns["ijl_load_and_lookup"]))
        call = LLVM.user(use)::LLVM.CallInst
        name = constant_cstring(LLVM.operands(call)[2])
        (name in RUNTIME_SHIM_FUNCTIONS || name in LIBC_FUNCTIONS) || continue
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
        "jl_f__task", "jl_f__svec_ref", "ijl_subtype",
        "ijl_object_id_", "jl_object_id_", "ijl_object_id", "jl_object_id", "jl_get_abi_converter", "ijl_load_and_lookup", "ijl_lazy_load_and_lookup", "jl_f_getfield",
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
    # hints for what is likely to be the cause
    if any(((_, inst),) -> occursin(r"%(stdout|stderr|stdin)\b", inst), e.pointers) ||
       any(((name, callers),) -> any(c -> c in ("print", "println", "format"), callers) && name == "ijl_apply_generic", e.dynamic)
        print(io, "\n\nHint: `stdout`, `stderr` and `stdin` of Base are globals of the abstract type `IO`, so what is done with them cannot be resolved when compiling. ",
              "Use `print`, `println` and `show` without an `IO` (which write to the standard output), or `STDOUT`, `STDERR` and `STDIN` of StaticCompilerOverrides, as in `println(STDERR, \"message\")`. ",
              "For `@printf`, which uses `stdout` if it has no `io`: `@printf(STDOUT, \"...\", x)`, or `printf(c\"...\", x)` of StaticTools.")
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

# Runtime functions that are given pointers to objects (types, exceptions) which they don't look into
const POINTER_ARGUMENTS_NOT_USED = Set([
    "jl_alloc_genericmemory_unchecked", "ijl_alloc_genericmemory_unchecked", "ijl_type_error",
    "ijl_undefined_var_error", "ijl_bounds_error_int", "ijl_bounds_error_unboxed_int", "ijl_bounds_error",
    "ijl_throw", "ijl_rethrow_other", "jl_argument_error", "gpu_unsupported_allocation",
    "julia.gc_alloc_bytes", "jl_f_throw_methoderror", "ijl_enter_handler", "ijl_pop_handler",
    "ijl_pop_handler_noexcept", "ijl_excstack_state", "ijl_restore_excstack",
])

# The places where code reads, writes or calls through a pointer to a Julia object that is not
# in the binary (an address from this process): these are certain to crash. Comparing such a
# pointer is common (type tags) and fine; passing it as an argument is too only to a few functions.
function unresolved_pointer_uses(mod::LLVM.Module)
    found = Tuple{String,String}[]
    seen = Set{Tuple{String,UInt}}()
    for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
        ops = if inst isa LLVM.LoadInst
            (LLVM.operands(inst)[1],)
        elseif inst isa LLVM.StoreInst
            Tuple(LLVM.operands(inst)[1:2])
        elseif inst isa LLVM.CallInst
            callee = LLVM.called_operand(inst)
            # the arguments too, unless the function only takes a pointer to something that
            # describes a type, or an error: those are not looked into
            name = callee isa LLVM.Function ? LLVM.name(callee) : ""
            name in POINTER_ARGUMENTS_NOT_USED ? (callee,) : (callee, LLVM.arguments(inst)...)
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

# (the objects of the program that are in the binary, by the address that they have in this process)
mutable struct ObjectEmbedder
    mod::LLVM.Module
    globals::Dict{UInt,Union{LLVM.GlobalVariable,Nothing}} # object address => its global
end

# an object we can't reproduce, and why
struct EmbedFailure <: Exception
    reason::String
end
EmbedFailure() = EmbedFailure("")

# Globals of the Julia runtime that hold a pointer to a well-known object (compiled code loads
# the pointer from the global). We make each point to a copy of the object in the binary.
const WELL_KNOWN_OBJECTS = (
    "jl_nothing" => nothing, "jl_emptytuple" => (), "jl_true" => true, "jl_false" => false,
    "jl_diverror_exception" => DivideError(), "jl_undefref_exception" => UndefRefError(),
    "jl_memory_exception" => OutOfMemoryError(), "jl_stackovf_exception" => StackOverflowError(),
    "jl_readonlymemory_exception" => ReadOnlyMemoryError(), "jl_interrupt_exception" => InterruptException(),
)

# The object in the binary that is the well-known object `obj` (which is one object, so that it is the one
# everything refers to, whether by its global, or by its address, as for any constant object, see
# `embed_global!`). It is preceded by its type tag as it is in this process.
function well_known_object!(e::ObjectEmbedder, name::AbstractString, obj)
    mod = e.mod
    globals = LLVM.globals(mod)
    haskey(globals, "static_$name") && return globals["static_$name"]
    addr = UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), obj))
    tag = unsafe_load(Ptr{UInt}(addr - 8)) & ~UInt(15)
    n = max(sizeof(typeof(obj)), 8) # room for at least a word, so that the address is a valid one
    payload = zeros(UInt8, n)
    sizeof(typeof(obj)) > 0 && unsafe_copyto!(pointer(payload), Ptr{UInt8}(addr), sizeof(typeof(obj)))
    st = LLVM.StructType([LLVM.Int64Type(), LLVM.Int64Type(), LLVM.ArrayType(LLVM.Int8Type(), n)]; packed = true)
    object = LLVM.GlobalVariable(mod, st, "static_$name")
    LLVM.linkage!(object, LLVM.API.LLVMLinkOnceODRLinkage)
    LLVM.visibility!(object, LLVM.API.LLVMHiddenVisibility)
    LLVM.alignment!(object, 16)
    # (the tag is of a type that may refer to this object: so after the global exists)
    LLVM.initializer!(object, LLVM.ConstantStruct(LLVM.Constant[LLVM.ConstantInt(Int64(0)), tag_piece(e, tag), LLVM.ConstantDataArray(LLVM.Int8Type(), payload)]; packed = true))
    return object
end

# which of the well-known objects is at an address, in this process
const WELL_KNOWN_ADDRESSES = Dict{UInt,Pair{String,Any}}()
function well_known_at(addr::UInt)
    if isempty(WELL_KNOWN_ADDRESSES)
        for (name, obj) in WELL_KNOWN_OBJECTS
            WELL_KNOWN_ADDRESSES[UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), obj))] = name => obj
        end
    end
    return get(WELL_KNOWN_ADDRESSES, addr, nothing)
end

function define_well_known_objects!(e::ObjectEmbedder)
    mod = e.mod
    changed = false
    for (name, obj) in WELL_KNOWN_OBJECTS
        globals = LLVM.globals(mod)
        haskey(globals, name) && LLVM.isdeclaration(globals[name]) || continue
        old = globals[name]
        object = well_known_object!(e, name, obj)
        pointer_to_object = LLVM.const_gep(LLVM.Int8Type(), object, [LLVM.ConstantInt(Int64(16))])
        LLVM.name!(old, name * ".declaration")
        new = LLVM.GlobalVariable(mod, LLVM.PointerType(), name)
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
    e = ObjectEmbedder(mod, Dict())
    define_well_known_objects!(e)
    lower_gc_frames!(mod)
    embed_constants!(e)
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
    shim = parse(LLVM.Module, shim_ir())
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
    n >= 0 && n < (1 << 28) || throw(EmbedFailure("implausible size"))
    n == 0 && return
    for off in 0:4096:(n - 1)
        safe_load(addr + off) === nothing && throw(EmbedFailure("unreadable memory"))
    end
    safe_load(addr + max(n - 8, 0)) === nothing && throw(EmbedFailure("unreadable memory"))
    return
end

const DATATYPE_TAG = Ref{UInt}(0) # the tag of `DataType` objects

# the type of the Julia object at `addr`, from its type tag, or `nothing` if it doesn't look
# like an object.
function object_type(addr::UInt)
    # All Julia objects are 16-byte aligned, which rules out many addresses that are not objects: in
    # particular the data of strings and arrays, which is 8 bytes after the start of the object. The
    # exception is symbols, which are 8-byte aligned (see `is_symbol` for checking one).
    addr >= 0x10000 && addr % 8 == 0 || return nothing
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
    T isa DataType && isconcretetype(T) || return nothing
    # the objects that are types (`typeof(Int)` is `DataType`) are objects as well, those of these kinds (the last is `Union{}`)
    (T <: Type) && !(T === DataType || T === UnionAll || T === Union || T === Core.TypeofBottom) && return nothing
    addr % 16 == 0 && return T
    return T === Symbol && is_symbol(addr) ? T : nothing
end

# Is the object at `addr`, of which the tag says that it is a symbol (and which is not aligned as
# other objects), one? A symbol is { left, right, hash, name }, where `left` and `right` are links
# to other symbols (or null), and the name is a C string, which we check to be reasonable, as
# the right-looking tag of a symbol may also be the length of a string.
function is_symbol(addr::UInt)
    for offset in (0, 8)
        link = safe_load(addr + offset)
        link === nothing && return false
        link == 0 && continue
        link % 8 == 0 && link >= 0x10000 || return false
        tag = safe_load(link - 8)
        tag === nothing && return false
        tag & ~UInt(15) == symbol_tag() || return false
    end
    safe_load(addr + 16) === nothing && return false
    # the name: at least one character, up to its NUL, of the characters that are fine in a name
    for i in 0:255
        word = safe_load(addr + 24 + 8 * (i ÷ 8))
        word === nothing && return false
        byte = UInt8((word >> (8 * (i % 8))) & 0xff)
        byte == 0x00 && return i > 0
        byte >= 0x20 && byte != 0x7f || return false
    end
    return false
end

const SYMBOL_TAG = Ref{UInt}(0) # the tag of symbols
symbol_tag() = (SYMBOL_TAG[] == 0 && (SYMBOL_TAG[] = unsafe_load(Ptr{UInt}(UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), :a)) - 8)) & ~UInt(15)); SYMBOL_TAG[])



const EMBED_ALIGN = 16
const EMBED_HEADER = 16 # the padding and the type tag before an object

# `LLVM` constants for the pieces of a global, to be laid out contiguously (packed)
bytes_piece(addr, n) = n == 0 ? nothing :
    LLVM.ConstantDataArray(LLVM.Int8Type(), copy(unsafe_wrap(Array, Ptr{UInt8}(addr), n)))
nullptr() = LLVM.PointerNull(LLVM.PointerType())
i64(x) = LLVM.ConstantInt(Int64(x))

function embed_global!(e::ObjectEmbedder, addr::UInt)
    if haskey(e.globals, addr)
        g = e.globals[addr]
        g === nothing && throw(EmbedFailure("an object that failed, or that it refers to"))
        return g
    end
    wk = well_known_at(addr)
    if wk !== nothing
        g = well_known_object!(e, first(wk), last(wk))
        e.globals[addr] = g
        return g
    end
    e.globals[addr] = nothing # failed, or in progress
    try
        return embed_new_global!(e, addr)
    catch err
        if err isa EmbedFailure && !isempty(err.reason)
            # (the path, from the object that can't be reproduced to the one we wanted)
            path = count("\n  <- ", err.reason) < 12 ? string(err.reason, "\n  <- ", object_type(addr), " at ", string(addr, base = 16)) : err.reason
            err = EmbedFailure(path)
            e.globals[addr] = nothing
            throw(err)
        end
        rethrow()
    end
end

function embed_new_global!(e::ObjectEmbedder, addr::UInt)
    T = object_type(addr)
    T === nothing && throw(EmbedFailure("not an object, at $(string(addr, base = 16)): tag word $(repr(safe_load(addr - 8)))"))
    # `values` needs the global, since objects may refer to themselves or to each other
    types, values = object_pieces(e, T, addr)
    # Before the object, as in Julia: its type tag (as it is in this process: the code that was compiled compares
    # with these), preceded by padding that makes the object aligned to 16 bytes
    tag = safe_load(addr - 8)
    tag === nothing && throw(EmbedFailure("no tag"))
    types = LLVM.LLVMType[LLVM.Int64Type(), LLVM.Int64Type(), types...]
    st = LLVM.StructType(types; packed=true)
    g = LLVM.GlobalVariable(e.mod, st, "static_object_$(string(addr, base=16))")
    # One object, whichever of the functions of a library refers to it: the functions are compiled
    # (and their modules linked) separately, so the global has the same name (that has the address of
    # the object in it) in each, and they are merged. It is hidden, so that two libraries don't share it.
    LLVM.linkage!(g, LLVM.API.LLVMLinkOnceODRLinkage)
    LLVM.visibility!(g, LLVM.API.LLVMHiddenVisibility)
    LLVM.alignment!(g, EMBED_ALIGN)
    e.globals[addr] = g
    try
        LLVM.initializer!(g, LLVM.ConstantStruct(LLVM.Constant[i64(0), tag_piece(e, tag & ~UInt(15)), values(g)...]; packed=true))
    catch
        e.globals[addr] = nothing
        LLVM.initializer!(g, LLVM.null(st))
        rethrow()
    end
    return g
end

# The tag of an object as the header of an embedded one: the small number of a builtin type, or the type: its
# address in the binary if it is one of those that are embedded (so that `isa` and `typeof` of the
# object have something to look at), and else its number in this process
function tag_piece(e::ObjectEmbedder, tag::UInt)
    tag < (64 << 4) && return i64(tag)
    ref = try
        embed_ref!(e, tag)
    catch err
        err isa EmbedFailure || rethrow()
        @debug "The type of an object is not in the binary, so its tag is a number" type = object_type(tag) reason = err.reason
        return i64(tag)
    end
    return LLVM.const_ptrtoint(ref, LLVM.Int64Type())
end

# a reference to the object at `addr` (or null), as an LLVM constant
function embed_ref!(e::ObjectEmbedder, addr::UInt, offset=0)
    addr == 0 && return nullptr()
    g = embed_global!(e, addr)
    return LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER + offset)])
end

function object_pieces(e::ObjectEmbedder, T::DataType, addr::UInt)
    if T === Module
        throw(EmbedFailure("a Module: a C struct of the runtime"))
    elseif T === Core.SimpleVector
        # { length, elements... }
        check_readable(addr, 8)
        n = unsafe_load(Ptr{Int}(addr))
        (0 <= n <= 100_000) || throw(EmbedFailure("implausible length of a svec"))
        check_readable(addr, 8 + 8n)
        refs = [unsafe_load(Ptr{UInt}(addr + 8 + 8(i - 1))) for i in 1:n]
        types = LLVM.LLVMType[LLVM.Int64Type(), (LLVM.PointerType() for _ in 1:n)...]
        return types, g -> LLVM.Constant[i64(n), (embed_ref!(e, r) for r in refs)...]
    elseif T === Symbol
        # { left, right (links of the table of symbols of the runtime), hash, name, NUL }: the name
        # is what is used, and as global constants are one object each, symbols are still egal
        check_readable(addr, 32)
        name_length = Int(ccall(:strlen, Csize_t, (Ptr{UInt8},), Ptr{UInt8}(addr + 24)))
        check_readable(addr, 24 + name_length + 1)
        types = LLVM.LLVMType[LLVM.PointerType(), LLVM.PointerType(), LLVM.Int64Type(), LLVM.ArrayType(LLVM.Int8Type(), name_length + 1)]
        hash = unsafe_load(Ptr{Int64}(addr + 16))
        return types, g -> LLVM.Constant[nullptr(), nullptr(), i64(hash), bytes_piece(addr + 24, name_length + 1)]
    elseif T === String
        check_readable(addr, 8)
        n = 8 + unsafe_load(Ptr{Int}(addr)) + 1
        check_readable(addr, n)
        return [LLVM.ArrayType(LLVM.Int8Type(), n)], g -> [bytes_piece(addr, n)]
    elseif T <: Core.GenericMemory
        return memory_pieces(e, T, addr)
    elseif isprimitivetype(T)
        # a boxed number, character, ...: its bytes
        n = sizeof(T)
        check_readable(addr, n)
        return LLVM.LLVMType[LLVM.ArrayType(LLVM.Int8Type(), n)], g -> LLVM.Constant[bytes_piece(addr, n)]
    elseif fieldcount(T) > 0
        return struct_pieces(e, T, addr)
    elseif Base.issingletontype(T)
        # the one instance of the type (a function, ...), which has no contents: padding, so that the object has an address
        pad = LLVM.ArrayType(LLVM.Int8Type(), 8)
        return LLVM.LLVMType[pad], g -> LLVM.Constant[LLVM.null(pad)]
    end
    throw(EmbedFailure("objects of type $T are not supported"))
end

# { length, data pointer, data... } with the data inline, as for the memory Julia allocates
function memory_pieces(e::ObjectEmbedder, T, addr::UInt)
    ET = eltype(T)
    check_readable(addr, 16)
    len = unsafe_load(Ptr{Int}(addr))
    data = unsafe_load(Ptr{UInt}(addr + 8))
    ptrT = LLVM.PointerType()
    if len == 0 # nothing in it, of whatever type its elements are
        types = LLVM.LLVMType[LLVM.Int64Type(), ptrT]
        return types, g -> LLVM.Constant[i64(0), LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER + 16)])]
    elseif isbitstype(ET) && Base.datatype_pointerfree(ET) # plain data
        n = len * Base.aligned_sizeof(ET)
        check_readable(data, n)
        types = LLVM.LLVMType[LLVM.Int64Type(), ptrT, LLVM.ArrayType(LLVM.Int8Type(), n)]
        return types, g -> LLVM.Constant[i64(len), LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER + 16)]), something(bytes_piece(data, n), LLVM.null(types[3]))]
    elseif !isbitstype(ET) && !(ET isa Union) && Base.allocatedinline(ET) == false # boxed elements
        check_readable(data, 8 * len)
        refs = [unsafe_load(Ptr{UInt}(data + 8(i - 1))) for i in 1:len]
        types = LLVM.LLVMType[LLVM.Int64Type(), ptrT, (ptrT for _ in 1:len)...]
        return types, g -> LLVM.Constant[i64(len), LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER + 16)]), (embed_ref!(e, r) for r in refs)...]
    end
    if ET isa DataType && Base.allocatedinline(ET) # structs with references in them, stored in it
        check_readable(data, len * sizeof(ET))
        element_types, element_values = struct_pieces(e, ET, data; n=len)
        types = LLVM.LLVMType[LLVM.Int64Type(), ptrT, element_types...]
        return types, g -> LLVM.Constant[i64(len), LLVM.const_gep(LLVM.Int8Type(), g, [i64(EMBED_HEADER + 16)]), element_values(g)...]
    end
    throw(EmbedFailure("memory of $ET"))
end

# the fields of a struct, in memory order, with padding copied as is
# Fields of the objects that are types, which are not reproduced, as they are the runtime's own and refer to
# most of what there is: a type refers to the types of its fields (`types`), a type name to the types
# that were made of it (`cache`), ... Code that reads these in a program that is run gets null, or an
# empty list, instead.
const EMPTY_SVEC = Ref{UInt}(0) # the address of the empty `svec()`
function field_cut(T::Type, name)
    EMPTY_SVEC[] == 0 && (EMPTY_SVEC[] = UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), Core.svec())))
    if T === DataType
        name === :types && return :sizedsvec
        return name === :layout ? :egalplan : nothing
    elseif T === Core.TypeName
        name in (:module, :atomicfields, :constfields, :partial, :Typeofwrapper, :mt) && return :null
        name in (:cache, :linearcache) && return :emptysvec
    end
    return nothing
end

# How `===` compares two objects of an immutable type, from the type, as the operations that the code for
# `jl_egal__unboxed` in the shim does (see there): comparing the contents of the fields in order, and the objects
# that the fields refer to. Julia's own `compare_fields` does this with the layout of the type and the types of its
# fields, which are not in the binary; this is what that comes to, for each type.
const EGAL_BYTES, EGAL_REF, EGAL_UNSUPPORTED = UInt32(0), UInt32(1), UInt32(2)

function egal_operations!(ops, dt::DataType, base::Int)
    for i in 1:fieldcount(dt)
        off = base + Int(fieldoffset(dt, i))
        ft = fieldtype(dt, i)
        if !Base.allocatedinline(ft)
            push!(ops, (EGAL_REF, off, 0))
        elseif !(ft isa DataType) || (fieldcount(ft) == 0 && Base.datatype_haspadding(ft))
            # (a field of a Union of types that are stored inline has a selector byte, and padding of the
            # types that have it is not compared)
            push!(ops, (EGAL_UNSUPPORTED, off, 0))
        elseif fieldcount(ft) == 0
            sizeof(ft) > 0 && push!(ops, (EGAL_BYTES, off, sizeof(ft)))
        else
            egal_operations!(ops, ft, off) # a struct that is stored inline in this one
        end
    end
    return ops
end

# the bytes of the memory before the `layout` of a type that has what `jl_egal__unboxed` needs: the operations,
# the number of them (negative for a mutable type), and then the layout as Julia has it. Its address is that of
# the layout. `nothing` for a type without a layout (an abstract one)
function egal_plan(dt::DataType)
    layout = unsafe_load(Ptr{Ptr{UInt8}}(pointer_from_objref(dt) + fieldoffset(DataType, findfirst(==(:layout), fieldnames(DataType)))))
    (layout == C_NULL || !isconcretetype(dt)) && return nothing
    # the size of the layout: its header, and the descriptions of the fields and the offsets of the pointers
    nfields, npointers = unsafe_load(Ptr{UInt32}(layout + 4)), unsafe_load(Ptr{UInt32}(layout + 8))
    fieldkind = Base.datatype_fielddesc_type(dt) + 1 # (8, 16 or 32 bit)
    layout_size = 20 + nfields * (2, 4, 8)[fieldkind] + npointers * (1, 2, 4)[fieldkind]
    ops = Tuple{UInt32,Int,Int}[]
    if ismutabletype(dt)
        count = -1
    else
        if fieldcount(dt) == 0 # a primitive type, or one without fields
            if sizeof(dt) > 0
                push!(ops, Base.datatype_haspadding(dt) ? (EGAL_UNSUPPORTED, 0, 0) : (EGAL_BYTES, 0, sizeof(dt)))
            end
        else
            egal_operations!(ops, dt, 0)
        end
        # (neighbors that are compared by bytes are one comparison)
        merged = Tuple{UInt32,Int,Int}[]
        for op in ops
            if !isempty(merged) && op[1] == EGAL_BYTES && merged[end][1] == EGAL_BYTES && merged[end][2] + merged[end][3] == op[2]
                merged[end] = (EGAL_BYTES, merged[end][2], merged[end][3] + op[3])
            else
                push!(merged, op)
            end
        end
        ops = merged
        count = length(ops)
    end
    io = IOBuffer()
    for (kind, off, size) in (count < 0 ? () : ops)
        write(io, kind, UInt32(off), UInt32(size), UInt32(0))
    end
    write(io, Int64(count))
    layout_offset = position(io)
    write(io, unsafe_wrap(Array, layout, layout_size))
    return take!(io), layout_offset
end

# The `layout` of the type at `addr` for the binary: a global with its plan (see `egal_plan`) and the layout
function egal_layout!(e::ObjectEmbedder, dt::DataType, addr::UInt)
    plan = egal_plan(dt)
    plan === nothing && return nullptr()
    bytes, layout_offset = plan
    contents = LLVM.ConstantDataArray(LLVM.Int8Type(), bytes)
    g = LLVM.GlobalVariable(e.mod, LLVM.value_type(contents), "static_egal_$(string(addr, base=16))")
    LLVM.linkage!(g, LLVM.API.LLVMLinkOnceODRLinkage)
    LLVM.visibility!(g, LLVM.API.LLVMHiddenVisibility)
    LLVM.alignment!(g, EMBED_ALIGN)
    LLVM.initializer!(g, contents)
    return LLVM.const_gep(LLVM.Int8Type(), g, [i64(layout_offset)])
end

# The `types` of a type is a list that is as long as the type has fields (the code that checks an index against the
# number of the fields of a type reads its length): one of that length, of `nothing`s, stands for it.
const SIZED_SVECS = Dict{Int,Core.SimpleVector}() # (kept, so that their addresses are not reused)
function sized_svec(n::Int)
    sv = get!(SIZED_SVECS, n) do
        Core.svec(ntuple(_ -> nothing, n)...)
    end
    return UInt(ccall(:jl_value_ptr, Ptr{Cvoid}, (Any,), sv))
end

# (`n` structs of the type, one after the other, as the elements of a `Memory` are)
function struct_pieces(e::ObjectEmbedder, T::DataType, addr::UInt; n::Int=1)
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
            cut = field_cut(T, fieldname(T, i))
            if cut === :null
                add!(LLVM.PointerType(), g -> nullptr())
                pos = off + sizeof(Ptr)
            elseif cut === :emptysvec
                add!(LLVM.PointerType(), g -> embed_ref!(e, EMPTY_SVEC[]))
                pos = off + sizeof(Ptr)
            elseif cut === :egalplan
                dt = unsafe_pointer_to_objref(Ptr{Cvoid}(addr))::DataType
                add!(LLVM.PointerType(), g -> egal_layout!(e, dt, addr))
                pos = off + sizeof(Ptr)
            elseif cut === :sizedsvec
                types_addr = unsafe_load(Ptr{UInt}(base + off))
                n = types_addr == 0 ? 0 : (check_readable(types_addr, 8); Int(unsafe_load(Ptr{Int}(types_addr))))
                add!(LLVM.PointerType(), g -> embed_ref!(e, sized_svec(n)))
                pos = off + sizeof(Ptr)
            elseif T <: Core.GenericMemoryRef && i == 1
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
            elseif Base.allocatedinline(ft) && ft isa Union # a Union of types without pointers, and a byte that says which
                stop = i < fieldcount(T) ? Int(fieldoffset(T, i + 1)) : sizeof(T)
                add_bytes!(base + off, stop - off)
                pos = stop
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
    for k in 0:n-1
        check_readable(addr + k * sizeof(T), sizeof(T))
        add_fields!(T, addr + k * sizeof(T))
    end
    isempty(types) && n > 0 && throw(EmbedFailure("no fields"))
    # values are created after the global, but the references they hold must exist before
    # it is (to compute the global's type), so they are created here and handed out later
    return types, g -> LLVM.Constant[thunk(g) for thunk in thunks]
end

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

# The constants that are the numbers (`i64`) of the addresses of type objects: code compares and stores the
# type tags of objects (which are those), as numbers. As (operand number, instruction) of a pair.
function type_number_constants(mod::LLVM.Module)
    consts = Dict{UInt,Vector{Tuple{LLVM.Instruction,Int}}}()
    for fn in LLVM.functions(mod), bb in LLVM.blocks(fn), inst in LLVM.instructions(bb)
        inst isa LLVM.SwitchInst && continue # (a case of a switch must be an integer)
        for (i, op) in enumerate(LLVM.operands(inst))
            op isa LLVM.ConstantInt || continue
            LLVM.width(LLVM.value_type(op)) == 64 || continue
            n = convert(UInt, op)
            (n >= (64 << 4) && n % 16 == 0) || continue
            object_type(n) === DataType || continue # the address of a type object
            push!(get!(Vector{Tuple{LLVM.Instruction,Int}}, consts, n), (inst, i))
        end
    end
    return consts
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
    fn = LLVM.parent(bb)
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
    successors = unique(Ptr{Cvoid}(b.ref) for b in vcat(destinations, [default]))
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

function embed_constants!(e::ObjectEmbedder)
    mod = e.mod
    # as comparisons, so that the types in them can be replaced (see `type_number_constants`)
    foreach(lower_switch!, type_switches(mod))
    changed = define_small_typeof!(e)
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
            continue
        end
        number = LLVM.const_ptrtoint(ref, LLVM.Int64Type())
        for (inst, i) in uses
            LLVM.operands(inst)[i] = number
        end
        changed = true
    end
    changed |= type_number_globals!(e)
    # drop the globals of objects that failed, and of objects only they referred to
    while true
        dead = [g for g in LLVM.globals(mod) if startswith(LLVM.name(g), "static_object_") && isempty(LLVM.uses(g))]
        isempty(dead) && break
        foreach(LLVM.erase!, dead)
    end
    return changed
end

end # module Runtime
