# The tests. `GROUP` (an environment variable) says which: `Core` (the compiler, the runtime and the language: `core/`), `Packages` (the standard libraries and the packages that
# programs use: `packages/`), or `All` (the default, so that `] test` runs both). `PACKAGES` (see `packages/runtests.jl`) selects some of the files of `Packages`.
#
# Most of the tests compile a program to an executable and compare what it prints with what Julia prints for the same code (`check_cases`, in `helpers.jl`).

# The terminal that the tests are run in is `xterm-256color` (set before anything asks for the terminfo: it is read once), as what Julia writes in color depends on it (italics, reverse and strikethrough, if the
# terminal has them), and a program does not read it: see `ext/StaticRuntimeStyledStringsExt.jl`. Julia has the terminfo of it, so that this does not depend on the system.
ENV["TERM"] = "xterm-256color"

using Test, Random, Printf, LinearAlgebra, Libdl, Dates, SparseArrays, Base64, CRC32c, Logging, Statistics
using SHA, UUIDs, Sockets, Unicode, TOML, Markdown, Mmap
using LLVM
using LLVM: @dispose
if Base.find_package("StaticRuntime") === nothing
    include(joinpath(@__DIR__, "..", "src", "StaticRuntime.jl"))
    using .StaticRuntime
else
    using StaticRuntime
end

const GROUP = get(ENV, "GROUP", "All")
GROUP in ("Core", "Packages", "All") || throw(ArgumentError("GROUP is `Core`, `Packages` or `All`, not `$GROUP`"))

include("helpers.jl")

GROUP in ("Core", "All") && include("core/runtests.jl")
GROUP in ("Packages", "All") && include("packages/runtests.jl")

if !isempty(get(ENV, "TEST_TIMING", ""))
    println("\nSeconds for each file of the tests:")
    for (path, t) in sort(FILE_TIMES; by = last, rev = true)
        println(lpad(round(t; digits = 1), 8), "  ", path)
    end
    println(lpad(round(sum(last, FILE_TIMES); digits = 1), 8), "  total")
end
