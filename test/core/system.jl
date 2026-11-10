# The operating system: the file system (paths, `stat`, directories, copying, temporary files), the environment (`ENV`), the process, the clock, `sleep`, and `Threads.@threads` (which runs
# the iterations one after another).
# The functions are the ones of Base, written with the functions of the C library (src/filesystem.jl); what they do is compared with Julia's (a directory is made for each case).

function threads_sum(s)
    Threads.@threads for i in 1:10
        Threads.atomic_add!(s, i)
    end
    return s[]
end

@testset "The file system and the process" begin
    dir() = (d = joinpath(tempdir(), string("static_cov_", Libc.getpid())); isdir(d) && rm(d; recursive = true); mkdir(d); d)
    check_cases([
        "paths"                    => () -> (println(basename("/a/b.txt"), dirname("/a/b.txt"), splitext("b.txt"), joinpath("a", "b"), normpath("/a/../b")); 0),
        "mkdir, isdir, rm"         => () -> (d = dir(); r = Int(isdir(d)); rm(d); r + Int(isdir(d)) + Int(ispath(d))),
        "files: isfile, filesize"  => () -> (d = dir(); p = joinpath(d, "f"); write(p, "hello"); r = Int(isfile(p)) + Int(ispath(p)) + filesize(p) + Int(isdir(p)); rm(d; recursive = true); r),
        "stat"                     => () -> (d = dir(); p = joinpath(d, "f"); write(p, "abc"); s = stat(p); r = Int(s.size) + Int(mtime(p) > 0) + Int(filemode(p) & 0o400 != 0); rm(d; recursive = true); r),
        "readdir"                  => () -> (d = dir(); write(joinpath(d, "b.txt"), "y"); write(joinpath(d, "a.txt"), "x"); mkdir(joinpath(d, "sub")); n = readdir(d); println(n); println(readdir(d; join = true) == joinpath.(d, n)); rm(d; recursive = true); length(n)),
        "cp and mv"                => () -> (d = dir(); p = joinpath(d, "f"); write(p, "abc"); cp(p, p * "2"); mv(p * "2", p * "3"); r = length(read(p * "3", String)) + Int(!ispath(p * "2")); rm(d; recursive = true); r),
        "cp of a directory"        => () -> (d = dir(); mkdir(joinpath(d, "s")); write(joinpath(d, "s", "x"), "hi"); cp(joinpath(d, "s"), joinpath(d, "t")); r = length(read(joinpath(d, "t", "x"), String)); rm(d; recursive = true); r),
        "rm of what is not there"  => () -> (d = dir(); rm(joinpath(d, "nothing"); force = true); r = (try; rm(joinpath(d, "nothing")); 0; catch e; 1; end); rm(d); r),
        "mkdir of one that exists" => () -> (d = dir(); r = (try; mkdir(d); 0; catch e; 1; end); rm(d); r),
        "pwd and cd"               => () -> (d = realpath(dir()); old = pwd(); cd(d); r = Int(realpath(pwd()) == d); cd(old); rm(d); r + Int(pwd() == old)),
        "temporary files"          => () -> ((p, io) = mktemp(); close(io); r = Int(isfile(p)); rm(p); q = tempname(); r + Int(!ispath(q)) + Int(isdir(tempdir()))),
        "mktempdir with a function" => () -> (path = mktempdir(d -> (write(joinpath(d, "x"), "1"); d)); Int(!ispath(path))),
        "environment"              => () -> (ENV["STATIC_COVERAGE_X"] = "5"; r = parse(Int, ENV["STATIC_COVERAGE_X"]) + Int(haskey(ENV, "STATIC_COVERAGE_X")); delete!(ENV, "STATIC_COVERAGE_X"); r + Int(haskey(ENV, "STATIC_COVERAGE_X"))),
        "process id and homedir"   => () -> Int(Libc.getpid() > 0) + Int(length(homedir()) > 0),
        "@threads"                 => () -> (s = Threads.Atomic{Int}(0); threads_sum(s)),
    ])
end


@testset "Time and threads" begin
    check_cases([
    "time_ns/time"          => () -> (t = time_ns(); Int(time_ns() >= t) + Int(time() > 1e9)),
    "nthreads"              => () -> Threads.nthreads(),
        "sleep"                   => () -> (t = time(); sleep(0.05); println(time() - t >= 0.04); 0),
        "sleep with a bad time"   => () -> (try; sleep(-1); catch e; println(e isa ArgumentError); end; 0),
    ], folded_ok = ("nthreads",)) # (the number of threads is the same for the whole run: a constant)
end
