# Programs that use MPI.jl, which `mpi.jl` compiles, and runs on 3 processes with `mpiexec`, and runs in Julia the same way, to compare what each process says.
# (The functions make one line, so that the lines of the processes do not mix; they are compared sorted.)
using MPI
line(rank, xs...) = (print(string("rank ", rank, ": ", xs..., "\n")); nothing)

function c_bcast(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    x = rank == 0 ? Float64[1, 2, 3] : zeros(3)
    MPI.Bcast!(x, 0, comm)
    line(rank, x)
    MPI.Finalize(); return 0
end
function c_reduce(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    x = Float64[rank + 1, 10 * (rank + 1)]
    r = MPI.Reduce(x, +, 0, comm)
    mx = MPI.Allreduce(rank * 1.5, max, comm)
    mn = MPI.Allreduce(Int32(rank + 5), min, comm)
    line(rank, r === nothing ? "none" : r, " ", mx, " ", mn)
    MPI.Finalize(); return 0
end
function c_gather(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm); size = MPI.Comm_size(comm)
    g = MPI.Gather([rank, rank * 10], 0, comm)
    ag = MPI.Allgather(Int32(rank + 100), comm)
    line(rank, g === nothing ? "none" : g, " ", ag)
    MPI.Finalize(); return 0
end
function c_scatter(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm); size = MPI.Comm_size(comm)
    sendbuf = rank == 0 ? collect(1.0:2size) : nothing
    recv = zeros(2)
    MPI.Scatter!(sendbuf === nothing ? nothing : MPI.UBuffer(sendbuf, 2), recv, 0, comm)
    line(rank, recv)
    MPI.Finalize(); return 0
end
function c_alltoall(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm); size = MPI.Comm_size(comm)
    send = Int[rank * 10 + j for j in 0:size-1]
    recv = MPI.Alltoall(MPI.UBuffer(send, 1), comm)
    line(rank, recv)
    MPI.Finalize(); return 0
end
function c_isend(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm); size = MPI.Comm_size(comm)
    sendbuf = Float64[rank, rank + 0.5]
    recvbuf = zeros(2)
    reqs = MPI.Request[]
    push!(reqs, MPI.Irecv!(recvbuf, comm; source = mod(rank - 1, size), tag = 7))
    push!(reqs, MPI.Isend(sendbuf, comm; dest = mod(rank + 1, size), tag = 7))
    MPI.Waitall(reqs)
    line(rank, recvbuf)
    MPI.Finalize(); return 0
end
function c_sendrecv(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm); size = MPI.Comm_size(comm)
    if rank == 0
        for r in 1:size-1
            MPI.Send(Int32[r * 7, r * 11], comm; dest = r, tag = 3)
        end
        line(rank, "sent")
    else
        buf = zeros(Int32, 2)
        (buf, status) = MPI.Recv!(buf, comm, MPI.Status; source = 0, tag = 3)
        line(rank, buf, " count=", MPI.Get_count(status, Int32), " source=", MPI.Get_source(status), " tag=", MPI.Get_tag(status))
    end
    MPI.Finalize(); return 0
end
function c_split(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    sub = MPI.Comm_split(comm, rank % 2, rank)
    srank = MPI.Comm_rank(sub); ssize = MPI.Comm_size(sub)
    total = MPI.Allreduce(rank + 1, +, sub)
    dup = MPI.Comm_dup(comm)
    line(rank, srank, "/", ssize, " total=", total, " dup=", MPI.Comm_size(dup))
    MPI.Finalize(); return 0
end
function c_scan(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    s = MPI.Scan(rank + 1, +, comm)
    e = MPI.Exscan(rank + 1, +, comm)
    line(rank, s, " ", e)
    MPI.Finalize(); return 0
end
function c_inplace(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    x = Float64[rank + 1, 2.0]
    MPI.Allreduce!(x, +, comm)
    y = Int[rank]
    MPI.Allreduce!(y, +, comm)
    line(rank, x, " ", y)
    MPI.Finalize(); return 0
end
function c_wtime(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    t0 = MPI.Wtime()
    MPI.Barrier(comm)
    t1 = MPI.Wtime()
    line(rank, t1 >= t0, " ", MPI.Wtick() > 0, " ", MPI.Initialized(), " ", MPI.Finalized())
    MPI.Finalize()
    return 0
end
function c_misc(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    name = MPI.Get_processor_name()
    v = MPI.Get_library_version()
    line(rank, length(name) > 0, " ", length(v) > 0, " ", MPI.Comm_size(MPI.COMM_SELF), " ", MPI.Comm_rank(MPI.COMM_SELF))
    MPI.Finalize(); return 0
end
function c_gatherv(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm); size = MPI.Comm_size(comm)
    send = fill(Float64(rank), rank + 1)
    counts = Cint[r + 1 for r in 0:size-1]
    recv = zeros(sum(counts))
    MPI.Gatherv!(send, rank == 0 ? MPI.VBuffer(recv, counts) : nothing, 0, comm)
    line(rank, rank == 0 ? recv : Float64[])
    MPI.Finalize(); return 0
end
function c_error(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    r = try
        MPI.Send(Int32[1], comm; dest = 99, tag = 0)
        "no error"
    catch e
        e isa MPI.MPIError ? string("MPIError ", e.code != 0) : "other"
    end
    line(rank, r)
    MPI.Finalize(); return 0
end
function c_probe(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm); size = MPI.Comm_size(comm)
    if rank == 0
        for r in 1:size-1
            MPI.Send(zeros(Float64, 3 + r), comm; dest = r, tag = 5)
        end
        line(rank, "sent")
    else
        st = MPI.Probe(0, 5, comm)
        n = MPI.Get_count(st, Float64)
        buf = zeros(n)
        MPI.Recv!(buf, comm; source = 0, tag = 5)
        line(rank, "probed ", n)
    end
    MPI.Finalize(); return 0
end
function c_many_comms(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    s = 0
    for i in 1:200
        d = MPI.Comm_dup(comm)
        s += MPI.Comm_size(d)
    end
    GC.gc()
    line(rank, s)
    MPI.Finalize(); return 0
end
function c_struct(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    x = Int32[rank, rank + 1]
    y = MPI.Allreduce(x, +, comm)
    z = MPI.Allreduce(Float32(rank), +, comm)
    w = MPI.Allreduce(ComplexF64(rank, 1), +, comm)
    line(rank, y, " ", z, " ", w)
    MPI.Finalize(); return 0
end
function c_cart(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm); size = MPI.Comm_size(comm)
    cart = MPI.Cart_create(comm, [size]; periodic = [true])
    src, dst = MPI.Cart_shift(cart, 0, 1)
    coords = MPI.Cart_coords(cart)
    line(rank, src, " ", dst, " ", coords)
    MPI.Finalize(); return 0
end
mymax(a, b) = a > b ? a : b
function c_customop(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    r = MPI.Allreduce(Float64(rank) + 0.5, mymax, comm)
    line(rank, r)
    MPI.Finalize(); return 0
end
function c_objects(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    if rank == 0
        MPI.send(Dict("a" => 1, "b" => [1.0, 2.0]), comm; dest = 1, tag = 1)
        line(rank, "sent")
    elseif rank == 1
        d, st = MPI.recv(comm, MPI.Status; source = 0, tag = 1)
        line(rank, d["a"], " ", d["b"])
    end
    MPI.Finalize(); return 0
end
function c_rma(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm); size = MPI.Comm_size(comm)
    buf = zeros(Float64, size); buf[1] = rank
    win = MPI.Win_create(buf, comm)
    MPI.Win_fence(0, win)
    if rank != 0
        MPI.Put!(Float64[rank * 100], 0, rank, win) # (each process writes a place of its own in the window of process 0)
    end
    MPI.Win_fence(0, win)
    line(rank, buf)
    MPI.free(win)
    MPI.Finalize(); return 0
end
function c_file(args::Vector{String})
    MPI.Init(); comm = MPI.COMM_WORLD; rank = MPI.Comm_rank(comm)
    path = joinpath(tempdir(), "mpi_static_probe.bin")
    f = MPI.File.open(comm, path; write = true, create = true)
    MPI.File.write_at_all(f, rank * 16, Float64[rank, rank + 0.5])
    MPI.File.close(f)
    MPI.Barrier(comm)
    f = MPI.File.open(comm, path; read = true)
    buf = zeros(2)
    MPI.File.read_at_all!(f, rank * 16, buf)
    MPI.File.close(f)
    line(rank, buf)
    MPI.Barrier(comm)
    rank == 0 && rm(path)
    MPI.Finalize(); return 0
end
# not compiled (see `mpi.jl`): a reduction with an operator of the user's (a C function that calls Julia), and `send` of any object (serialization)
const CASES = [c_bcast, c_reduce, c_gather, c_scatter, c_alltoall, c_isend, c_sendrecv, c_split, c_scan, c_inplace, c_wtime, c_misc, c_gatherv, c_error, c_probe, c_many_comms, c_struct, c_cart, c_customop, c_objects, c_rma, c_file]
