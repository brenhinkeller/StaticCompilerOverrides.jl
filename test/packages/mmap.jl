# Mmap: files that are mapped to memory by their path, as arrays of bytes, numbers and matrices, from an offset, and new files that are made as long as the array needs.
# (From an open stream, and anonymous mappings, are not supported: see `ext/StaticCompilerOverridesMmapExt.jl`.)

@testset "Mmap" begin
    check_cases([
        "bytes of a file"         => () -> (p = tempname(); write(p, opaque("abcdef")); a = Mmap.mmap(p); Int(a[1]) + length(a) * 1000),
        "a Vector of Int"         => () -> (p = tempname(); write(p, Int[opaque(1), 2, 3, 4]); a = Mmap.mmap(p, Vector{Int}); sum(a) * 10 + length(a)),
        "a Matrix"                => () -> (p = tempname(); write(p, Float64.(1:opaque(6))); a = Mmap.mmap(p, Matrix{Float64}, (2, 3)); Int(a[2, 3] + a[1, 2]) * 10 + size(a, 1)),
        "the length is given"     => () -> (p = tempname(); write(p, UInt8.(1:opaque(20))); a = Mmap.mmap(p, Vector{UInt8}, 10); Int(sum(a)) + length(a) * 1000),
        "from an offset (not a multiple of the page)" => () -> (p = tempname(); write(p, UInt8.(1:opaque(20))); a = Mmap.mmap(p, Vector{UInt8}, (5,), 3); Int(a[1]) * 100 + Int(sum(a))),
        "a new file is made, written, and read" => () -> (p = tempname(); a = Mmap.mmap(p, Vector{Int32}, (opaque(4),)); a .= 7; a[2] = 9; Mmap.sync!(a); b = Mmap.mmap(p, Vector{Int32}); Int(sum(b)) + filesize(p) * 1000),
        "a large file"            => () -> (p = tempname(); write(p, Float64.(1:opaque(10000))); a = Mmap.mmap(p, Vector{Float64}); Int(sum(a))),
        "no elements"             => () -> (p = tempname(); write(p, ""); a = Mmap.mmap(p, Vector{UInt8}, 0); length(a) + opaque(0)),
        "more than the file has"  => () -> (p = tempname(); write(p, opaque("abc")); try; Mmap.mmap(p, Vector{UInt8}, 100); 0; catch e; e isa ArgumentError ? 1 : 2; end),
        "a path that cannot be made" => () -> (try; Mmap.mmap("/nonexistent/dir/file", Vector{UInt8}, opaque(10)); 0; catch e; e isa SystemError ? 1 : 2; end),
    ])
end
