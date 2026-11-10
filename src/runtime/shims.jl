# The runtime that compiled code links to, written in LLVM IR (`RUNTIME_SHIM_IR`): the functions of libjulia that the code that Julia generates calls (allocation of strings and boxes,
# `jl_f_*` builtins, exceptions, ...), and the lists of the functions that it may call without them (the C library and the math library) or that are replaced (`LIBJULIA_ALIASES`).
# A program is linked with the part of this that it uses (see `link_runtime!`).

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
; (the field of the task that has the current scope, 152 bytes before it, is `nothing`, the object that the program has (see `link_runtime!`): the
; values of a `ScopedValue` are not set, as it is in a task that none has set one in)
@static_jl_nothing = external hidden global i8
@_static_task = internal global { [45 x i64], ptr, [82 x i64] } { [45 x i64] zeroinitializer, ptr getelementptr inbounds (i8, ptr @static_jl_nothing, i64 16), [82 x i64] zeroinitializer }, align 16

define internal void @_static_oom() noreturn {
  %s = call i32 @puts(ptr @_static_oom_msg)
  call void @exit(i32 1)
  unreachable
}

; Objects have a header of 16 bytes before them, as in Julia: the type tag, in the 8 bytes before the
; object (which compiled code may write: see `julia.gc_alloc_bytes` below), and padding, so that the
; object is aligned to 16 bytes. The heap (`heap.jl`), written in Julia, is linked in (see `link_heap!`), and
; has the function that allocates, with the kind of the object: 0 if it may hold references to other objects,
; and 1 if it can't (a string, an array of numbers, a boxed number), which the collector doesn't look inside.
declare ptr @static_alloc(i64, i64)

define linkonce_odr ptr @gpu_gc_pool_alloc(i64 %sz) {
  %p = call ptr @static_alloc(i64 %sz, i64 0)
  ret ptr %p
}

define linkonce_odr ptr @gpu_gc_pool_alloc_atomic(i64 %sz) {
  %p = call ptr @static_alloc(i64 %sz, i64 1)
  ret ptr %p
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

; The sizes below are checked against what could be allocated at all (a length that is negative, as a number of bytes, is a very large one):
; without it, adding the header to it wraps around, and the object is small, and what is then written to it is not.
; Memory{T} (Julia 1.11+): { length, data pointer } header followed by inline data.
; The caller fills in the length. Zeroed, as Julia does for pointer-containing memory.
define linkonce_odr ptr @jl_alloc_genericmemory_unchecked(ptr %ptls, i64 %nbytes, ptr %ty) {
  %toobig = icmp ugt i64 %nbytes, 4611686018427387903
  br i1 %toobig, label %oom, label %ok
oom:
  call void @_static_oom()
  unreachable
ok:
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

; The same for the memory of elements that are not references (`jl_alloc_genericmemory_atomic`, which calls to the above are
; made for by `classify_allocations!`), which the collector doesn't look inside
define linkonce_odr ptr @jl_alloc_genericmemory_atomic(ptr %ptls, i64 %nbytes, ptr %ty) {
  %toobig = icmp ugt i64 %nbytes, 4611686018427387903
  br i1 %toobig, label %oom, label %ok
oom:
  call void @_static_oom()
  unreachable
ok:
  %total = add i64 %nbytes, 16
  %obj = call ptr @gpu_gc_pool_alloc_atomic(i64 %total)
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
  %i32d = icmp eq i64 %dtag, {{TAG_FLOAT32}}
  %i64a = icmp eq i64 %dtag, {{TAG_INT64}}
  %i64b = icmp eq i64 %dtag, {{TAG_UINT64}}
  %i64c = icmp eq i64 %dtag, {{TAG_FLOAT64}}
  %c1 = or i1 %i8a, %i8b
  %c2 = or i1 %i16a, %i16b
  %c4a = or i1 %i32a, %i32b
  %c4b = or i1 %c4a, %i32c
  %c4 = or i1 %c4b, %i32d
  %c8a = or i1 %i64a, %i64b
  %c8 = or i1 %c8a, %i64c
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
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_INT64}}, ptr %tagslot, align 8
  store i64 %v, ptr %p, align 8
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_uint64(i64 %v) {
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_UINT64}}, ptr %tagslot, align 8
  store i64 %v, ptr %p, align 8
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_int32(i32 %v) {
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_INT32}}, ptr %tagslot, align 8
  store i32 %v, ptr %p, align 4
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_uint32(i32 %v) {
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_UINT32}}, ptr %tagslot, align 8
  store i32 %v, ptr %p, align 4
  ret ptr %p
}

define linkonce_odr ptr @ijl_box_int8(i8 %v) {
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_INT8}}, ptr %tagslot, align 8
  store i8 %v, ptr %p, align 1
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_uint8(i8 %v) {
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_UINT8}}, ptr %tagslot, align 8
  store i8 %v, ptr %p, align 1
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_int16(i16 %v) {
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_INT16}}, ptr %tagslot, align 8
  store i16 %v, ptr %p, align 2
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_uint16(i16 %v) {
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_UINT16}}, ptr %tagslot, align 8
  store i16 %v, ptr %p, align 2
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_float32(float %v) {
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_FLOAT32}}, ptr %tagslot, align 8
  store float %v, ptr %p, align 4
  ret ptr %p
}
define linkonce_odr ptr @ijl_box_float64(double %v) {
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_FLOAT64}}, ptr %tagslot, align 8
  store double %v, ptr %p, align 8
  ret ptr %p
}

define linkonce_odr ptr @ijl_box_char(i32 %v) {
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 8)
  %tagslot = getelementptr inbounds i8, ptr %p, i64 -8
  store i64 {{TAG_CHAR}}, ptr %tagslot, align 8
  store i32 %v, ptr %p, align 4
  ret ptr %p
}

; String (Julia 1.11+): { length, data..., NUL }
define linkonce_odr ptr @ijl_alloc_string(i64 %n) {
  %toobig = icmp ugt i64 %n, 4611686018427387903
  br i1 %toobig, label %oom, label %ok
oom:
  call void @_static_oom()
  unreachable
ok:
  %total = add i64 %n, 9
  %p = call ptr @gpu_gc_pool_alloc_atomic(i64 %total)
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

; A finalizer that is a C function (`BigInt` has one, to free what GMP allocated): the heap has it called with the object when
; a collection finds that nothing refers to the object (see `heap.jl`). (A finalizer that is a Julia function is not this: see `finalizers.jl`.)
define linkonce_odr void @ijl_gc_add_ptr_finalizer(ptr %ptls, ptr %obj, ptr %f) {
  %fi = ptrtoint ptr %f to i64
  %oi = ptrtoint ptr %obj to i64
  %r1 = call ptr @static_alloc(i64 -7, i64 %fi)
  %r2 = call ptr @static_alloc(i64 -8, i64 %oi)
  ret void
}

; (nothing is waiting to be run: finalizers are run by the collection)
define linkonce_odr i32 @jl_gc_have_pending_finalizers() {
  ret i32 0
}

define linkonce_odr void @jl_gc_run_pending_finalizers(ptr %ptls) {
  ret void
}

define linkonce_odr ptr @jl_cstr_to_string(ptr %p) {
  %s = call ptr @ijl_cstr_to_string(ptr %p)
  ret ptr %s
}

; a Memory of the type `%ty` over data that the program does not own (`unsafe_wrap`): the data is not freed with it, whatever `own` says
define linkonce_odr ptr @ijl_ptr_to_genericmemory(ptr %ty, ptr %data, i64 %n, i32 %own) {
  %m = call ptr @gpu_gc_pool_alloc(i64 16)
  %tagslot = getelementptr inbounds i8, ptr %m, i64 -8
  %tag = ptrtoint ptr %ty to i64
  store i64 %tag, ptr %tagslot, align 8
  store i64 %n, ptr %m, align 8
  %slot = getelementptr inbounds i8, ptr %m, i64 8
  store ptr %data, ptr %slot, align 8
  ret ptr %m
}

define linkonce_odr ptr @jl_ptr_to_genericmemory(ptr %ty, ptr %data, i64 %n, i32 %own) {
  %m = call ptr @ijl_ptr_to_genericmemory(ptr %ty, ptr %data, i64 %n, i32 %own)
  ret ptr %m
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

; only reached for elements that are not `isbits`: references (pointer-sized), and structs that contain references, stored
; inline. The size of an element is in the layout of the type of the memory (its first field), which is there when the
; code has what it needs of the types for `===` (see `egal_layout!`: it is for this as well)
define linkonce_odr void @jl_genericmemory_copyto(ptr %dm, ptr %dd, ptr %sm, ptr %sd, i64 %n) {
  %tagp = getelementptr inbounds i8, ptr %dm, i64 -8
  %tag = load i64, ptr %tagp, align 8
  %dtag = and i64 %tag, -16
  %dt = inttoptr i64 %dtag to ptr
  %lp = getelementptr inbounds i8, ptr %dt, i64 {{LAYOUT_OFFSET}}
  %layout = load ptr, ptr %lp, align 8
  %elsz32 = load i32, ptr %layout, align 4
  %elsz = zext i32 %elsz32 to i64
  %bytes = mul i64 %n, %elsz
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

# `RUNTIME_SHIM_IR`, with the type tags of the types of the objects that it makes
function shim_ir()
    ir = RUNTIME_SHIM_IR
    ir = replace(ir, "{{LAYOUT_OFFSET}}" => string(fieldoffset(DataType, findfirst(==(:layout), fieldnames(DataType)))))
    for (token, example) in ("TAG_STRING" => "", "TAG_INT64" => 1, "TAG_UINT64" => UInt64(1),
                             "TAG_INT32" => Int32(1), "TAG_UINT32" => UInt32(1),
                             "TAG_INT8" => Int8(1), "TAG_UINT8" => UInt8(1), "TAG_INT16" => Int16(1),
                             "TAG_UINT16" => UInt16(1), "TAG_CHAR" => 'a', "TAG_FLOAT32" => 1f0, "TAG_FLOAT64" => 1.0,
                             "TAG_SYMBOL" => :a, "TAG_BOOL" => true, "TAG_NOTHING" => nothing,
                             "TAG_MEMORY_UINT8" => Memory{UInt8}(undef, 1))
        ir = replace(ir, "{{$token}}" => string(object_tag(example)))
    end
    return ir
end

# the runtime functions defined by `RUNTIME_SHIM_IR`, which override declarations in `mod`
const RUNTIME_SHIM_FUNCTIONS = (
    "gpu_gc_pool_alloc", "gpu_gc_pool_alloc_atomic", "gpu_unsupported_allocation",
    "jl_alloc_genericmemory_unchecked", "jl_alloc_genericmemory_atomic",
    "jl_argument_error", "jl_egal__unboxed", "julia.get_pgcstack", "julia.gc_alloc_bytes", "julia.safepoint", "julia.cancellation_point", "julia.get_pgcstack_or_new",
    "ijl_enter_handler", "ijl_pop_handler", "ijl_pop_handler_noexcept", "ijl_excstack_state",
    "ijl_restore_excstack", "ijl_throw", "ijl_rethrow", "ijl_rethrow_other",
    "ijl_current_exception", "jl_current_exception",
    "ijl_box_int64", "ijl_box_uint64", "ijl_box_int32", "ijl_box_uint32", "ijl_box_char",
    "ijl_box_int8", "ijl_box_uint8", "ijl_box_int16", "ijl_box_uint16", "ijl_box_float32", "ijl_box_float64",
    "ijl_alloc_string", "ijl_pchar_to_string", "jl_pchar_to_string", "ijl_cstr_to_string", "jl_cstr_to_string", "jl_string_to_genericmemory", "jl_genericmemory_to_string",
    "jl_genericmemory_copyto",
    "ijl_gc_add_ptr_finalizer", "jl_gc_have_pending_finalizers", "jl_gc_run_pending_finalizers",
    "ijl_ptr_to_genericmemory", "jl_ptr_to_genericmemory",
)

# Functions of the C library and of the math library, which every executable links to: a `ccall` to
# these is a call to the function.
const LIBC_FUNCTIONS = Set([
    "strlen", "strnlen", "memcpy", "memmove", "memset", "memcmp", "memchr", "strcmp", "strncmp",
    "strchr", "strrchr", "strstr", "malloc", "calloc", "realloc", "free", "abort", "exit", "getenv",
    "atoi", "strtol", "strtoul", "strtoll", "strtoull", "strtod", "strtof", "qsort", "bsearch",
    "write", "read", "puts", "putchar", "getchar", "fflush", "fputc", "fputs", "fwrite", "fread",
    "usleep", "nanosleep", "atexit", "clock_gettime", "time", "getentropy", "gettimeofday", "localtime_r", "gmtime_r",
    "stat", "lstat", "stat\$INODE64", "lstat\$INODE64", "access", "mkdir", "rmdir", "unlink", "rename", "opendir", "readdir", "closedir", "getcwd", "chdir", "realpath",
    "mkstemp", "mkdtemp", "fdopen", "getpid", "setenv", "unsetenv", "strerror", "close", "__error", "__errno_location",
    # libm
    "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "asinh", "acosh",
    "atanh", "exp", "exp2", "expm1", "log", "log2", "log10", "log1p", "pow", "sqrt", "cbrt", "hypot",
    "fabs", "floor", "ceil", "trunc", "round", "rint", "nearbyint", "fmod", "remainder", "ldexp",
    "frexp", "modf", "erf", "erfc", "tgamma", "lgamma", "copysign", "fma", "fmin", "fmax",
    ("$(f)f" for f in ("sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "exp",
                       "exp2", "expm1", "log", "log2", "log10", "log1p", "pow", "sqrt", "cbrt", "hypot",
                       "fabs", "floor", "ceil", "trunc", "round", "rint", "fmod", "ldexp", "copysign"))...,
])

# Functions of libjulia that are the C library's (SuiteSparse is given them as its allocators): they are those, here
const LIBJULIA_ALIASES = Dict("jl_malloc" => "malloc", "ijl_malloc" => "malloc", "jl_calloc" => "calloc", "ijl_calloc" => "calloc",
                              "jl_realloc" => "realloc", "ijl_realloc" => "realloc", "jl_free" => "free", "ijl_free" => "free")

# Julia binds `ccall`s lazily, through `ijl_load_and_lookup(lib, name, handle)`. For the symbols the
# runtime shim implements, and those of the C library, resolve the lookup statically instead.
function resolve_lazy_lookups!(mod::LLVM.Module)
    fns = LLVM.functions(mod)
    haskey(fns, "ijl_load_and_lookup") || return false
    changed = false
    for use in collect(LLVM.uses(fns["ijl_load_and_lookup"]))
        call = LLVM.user(use)::LLVM.CallInst
        name = constant_cstring(LLVM.operands(call)[2])
        name = get(LIBJULIA_ALIASES, name, name)
        (name in RUNTIME_SHIM_FUNCTIONS || name in LIBC_FUNCTIONS) || continue
        target = haskey(fns, name) ? fns[name] :
                 LLVM.Function(mod, name, LLVM.FunctionType(LLVM.VoidType()))
        LLVM.replace_uses!(call, target)
        LLVM.erase!(call)
        changed = true
    end
    return changed
end
