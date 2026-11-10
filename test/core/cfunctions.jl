# `@cfunction`: C functions that call functions of the program (src/cfunctions.jl, src/cfunctions_link.jl), called by `qsort` and `bsearch` of the C library, and from Julia. The cases are
# compiled one by one: each program has its own targets.

cov_cmp_ints(a::Ptr{Cint}, b::Ptr{Cint})::Cint = (x = unsafe_load(a); y = unsafe_load(b); x < y ? Cint(-1) : x > y ? Cint(1) : Cint(0))
cov_cmp_desc(a::Ptr{Cdouble}, b::Ptr{Cdouble})::Cint = (x = unsafe_load(a); y = unsafe_load(b); x > y ? Cint(-1) : x < y ? Cint(1) : Cint(0))
cov_cmp_alloc(a::Ptr{Cint}, b::Ptr{Cint})::Cint = (v = [unsafe_load(a), unsafe_load(b)]; v[1] < v[2] ? Cint(-1) : v[1] > v[2] ? Cint(1) : Cint(0)) # (allocates)
const cov_cmp_count = Ref(0)
cov_cmp_counting(a::Ptr{Cint}, b::Ptr{Cint})::Cint = (cov_cmp_count[] += 1; cov_cmp_ints(a, b))
const cov_flag = Ref(0)
cov_set_flag(x::Cint)::Cvoid = (cov_flag[] = x; nothing)
cov_inc(x::Cint)::Cint = x + Cint(1)

@testset "@cfunction" begin
    qsorted(v::Vector{Cint}, f) = (ccall(:qsort, Cvoid, (Ptr{Cint}, Csize_t, Csize_t, Ptr{Cvoid}), v, length(v), 4, f); v)
    qsorted(v::Vector{Cdouble}, f) = (ccall(:qsort, Cvoid, (Ptr{Cdouble}, Csize_t, Csize_t, Ptr{Cvoid}), v, length(v), 8, f); v)
    digits3(v) = Int(v[1]) * 100 + Int(v[2]) * 10 + Int(v[3])
    check_cases([
        "qsort of integers"         => () -> digits3(qsorted(Cint[3, 1, 2], @cfunction(cov_cmp_ints, Cint, (Ptr{Cint}, Ptr{Cint})))),
        "qsort of doubles"          => () -> (v = qsorted([1.5, 3.5, 2.5], @cfunction(cov_cmp_desc, Cint, (Ptr{Cdouble}, Ptr{Cdouble}))); round(Int, 10v[1]) * 100 + round(Int, 10v[2]) * 10 + round(Int, 10v[3]) % 10),
        "qsort of many"             => () -> (v = Cint[mod(i * 7919, 1000) for i in 1:500]; qsorted(v, @cfunction(cov_cmp_ints, Cint, (Ptr{Cint}, Ptr{Cint}))); Int(issorted(v)) + Int(v[1]) + Int(v[end])),
        "a callback that allocates" => () -> digits3(qsorted(Cint[9, 7, 8], @cfunction(cov_cmp_alloc, Cint, (Ptr{Cint}, Ptr{Cint})))),
        "a callback that counts"    => () -> (cov_cmp_count[] = 0; qsorted(Cint[5, 4, 3, 2, 1], @cfunction(cov_cmp_counting, Cint, (Ptr{Cint}, Ptr{Cint}))); Int(cov_cmp_count[] > 0)),
        "two callbacks"             => () -> (a = qsorted(Cint[3, 1, 2], @cfunction(cov_cmp_ints, Cint, (Ptr{Cint}, Ptr{Cint}))); b = qsorted(Cint[1, 3, 2], @cfunction(cov_cmp_alloc, Cint, (Ptr{Cint}, Ptr{Cint}))); digits3(a) + digits3(b)),
        "bsearch"                   => () -> (v = Cint[1, 3, 5, 7]; key = Ref(Cint(5)); p = ccall(:bsearch, Ptr{Cint}, (Ref{Cint}, Ptr{Cint}, Csize_t, Csize_t, Ptr{Cvoid}), key, v, 4, 4, @cfunction(cov_cmp_ints, Cint, (Ptr{Cint}, Ptr{Cint}))); Int(p - pointer(v)) ÷ 4),
        "called from Julia"         => () -> (f = @cfunction(cov_inc, Cint, (Cint,)); Int(ccall(f, Cint, (Cint,), 41))),
        "a callback of no value"    => () -> (cov_flag[] = 0; ccall(@cfunction(cov_set_flag, Cvoid, (Cint,)), Cvoid, (Cint,), 7); cov_flag[]),
        "a lambda"                  => () -> (f = @cfunction(x -> x * Cint(2), Cint, (Cint,)); Int(ccall(f, Cint, (Cint,), 21))),
        "the pointer is not null"   => () -> Int(@cfunction(cov_inc, Cint, (Cint,)) != C_NULL),
    ]; batch = false)
end
