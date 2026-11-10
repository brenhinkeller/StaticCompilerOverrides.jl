# Printf: `@printf`, `@sprintf` and `Printf.format`, compared with Julia's (printf of StaticTools, with C's specifiers, is in `core/printing.jl`).

const FORMAT = Printf.Format("%s=%08.3f\n") # made once, as `@printf` does

@testset "Printf" begin
    check_cases([
    "@printf"               => () -> (Printf.@printf("%d %.2f\n", 3, 2.5); 1),
    "@printf STDOUT"        => () -> (Printf.@printf(STDOUT, "%d %5.2f %s\n", 3, 2.5, "x"); 1),
    # Printf (Julia's own formats: `%d` is for any integer)
    "sprintf"               => () -> length(Printf.@sprintf("%d %5.2f %s %c %x|%-6s|%+d", 12, 3.14159, "str", 'z', 255, "ab", 5)),
    "sprintf Int64/Float32" => () -> length(Printf.@sprintf("%d %d %f %g %e", typemax(Int64), Int8(-3), 1.5f0, 0.1, 12345.678)),
    "@printf STDERR"        => () -> (Printf.@printf(STDERR, "e %d %s\n", 3, "x"); 1),
    "Printf.format"         => () -> (Printf.format(STDOUT, FORMAT, "pi", 3.14159); 1),
    "Printf.Format runtime" => () -> (Printf.format(STDOUT, Printf.Format("%s=%08.3f\n"), "pi", 3.14159); 1),
    "@printf unicode/%%"    => () -> (Printf.@printf(STDOUT, "%s 100%% %5s|\n", "é∑", "日本"); 1),
    ], broken = ("@printf", "Printf.Format runtime"))
end
