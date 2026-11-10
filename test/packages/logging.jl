# Logging: `@info`, `@warn`, `@error` to the standard error, `NullLogger`, and what Julia writes for each (the line of the message, its keywords, the place that it is at).

const LOG_LINE = (@__LINE__) + 1
log_message(n::Int) = (n > 1 && @warn "big n" n; @info "info message" n x = 2.5 name = "abc"; @debug "hidden" n; n + 1)
log_interpolated(n::Int) = (@warn "number $n"; @error "bad" maxlog = 1; n + 1)

@testset "Logging" begin
    err = stderr_of(() -> log_message(Base.inferencebarrier(3)))
    lines = split(err, '\n')
    @test lines[1] == "┌ Warning: big n"
    @test lines[2] == "│   n = 3"
    @test startswith(lines[3], "└ @ ") && endswith(lines[3], "logging.jl:" * string(LOG_LINE))
    @test lines[4] == "┌ Info: info message"
    @test lines[5:7] == ["│   n = 3", "│   x = 2.5", "│   name = abc"]
    @test !occursin("hidden", err) # (`@debug` is off, as it is in Julia)
    # (not shown when the condition is not met)
    @test !occursin("big n", stderr_of(() -> log_message(Base.inferencebarrier(1))))
    # a message that is made when it is written, and `maxlog` (which is not kept: the message is written each time)
    err = stderr_of(() -> log_interpolated(Base.inferencebarrier(7)))
    @test occursin("┌ Warning: number 7\n", err) && occursin("┌ Error: bad\n", err) && !occursin("maxlog", err)
    # the program goes on, and gives the same result
    @test static_result(() -> log_message(Base.inferencebarrier(3))) == 4
end

@testset "NullLogger" begin
    check_cases([
        "NullLogger"               => () -> (with_logger(NullLogger()) do; @warn "hidden"; end; 0),
    ])
end

