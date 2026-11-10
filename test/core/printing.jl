# `print`, `println`, `show`, `repr`, `string`, `sprint` and the standard streams (`STDOUT`, `STDERR`), and `printf` of StaticTools: what is written is compared with what Julia writes.
# (`show` of containers, types and structs is in `show.jl` (so the same containers are not printed here), arrays of more than one dimension in `arrays.jl`, and `text/plain` in `plain.jl`.)

# the global `stderr` has the abstract type `IO`: a program says `STDERR`
@testset "print and show" begin
    check_cases([
    # printing
    "println Int"           => () -> (println(42); 1),
    "println String"        => () -> (println("hello"); 1),
    "print Float64"         => () -> (print(1.5); print(" "); println(2.0); 1),
    "println Bool/Char"     => () -> (println(true); println('x'); 1),
    "println mixed"         => () -> (println("a", 1, 'b', 2.5); 1),
    "interpolation"         => () -> (x = 3; println("x = $x, y = $(2x)"); 1),
    "println Vector Float64" => () -> (println([1.5, 2.0]); 1),
    "show"                  => () -> (show(7); println(); 1),
    "print in loop"         => () -> (for i in 1:3; println(i); end; 1),
    "string mixed"          => () -> length(string("a", 1, 'b', 2.5)),
    "sprint"                => () -> length(sprint(print, 12345)),
    "stderr"                => () -> (println(stderr, "to stderr"); 1),
    "STDOUT"                => () -> (println(STDOUT, "explicit ", 1, ' ', 2.5); print(STDOUT, "x", 'y'); println(STDOUT); 1),
    "STDERR"                => () -> (println(STDERR, "to stderr"); print(STDERR, 1, 2, 3); println(STDERR); 1),
    "STDOUT show"           => () -> (show(STDOUT, 12); show(STDOUT, "str"); show(STDOUT, 'c'); println(STDOUT); 1),
    "STDOUT flush"          => () -> (print(STDOUT, "a"); flush(STDOUT); print(STDERR, "b"); flush(STDERR); println(STDOUT); 1),
    # printf of StaticTools (C's format specifiers); libc's stdout throughout, as `STDOUT` is
    "printf one"            => () -> (printf(c"%d\n", 42); printf(c"%5.2f|\n", 2.5); 1),
    "printf several"        => () -> (printf(c"%d + %d = %d\n", 1, 2, 3); printf(c"%s has %5.2f%% of %lld\n", c"x", 12.345, 10^12); 1),
    "printf types"          => () -> (printf(c"%d %d %u %x %.3f %.1f\n", Int8(-5), Int16(-300), UInt8(200), UInt16(255), 1.5f0, Float16(2.5)); 1),
    "printf String arg"     => () -> (printf(c"%s|%s|%s\n", "julia", c"static", string("a", 1)); 1),
    "printf in loop"        => () -> (for i in 1:4; printf(c"%d: %6.3f %s\n", i, i / 3, i % 2 == 0 ? c"even" : c"odd"); end; 1),
    "printf STDOUT STDERR"  => () -> (printf(STDOUT, c"out %d %s\n", 1, c"x"); printf(STDERR, c"err %d %s\n", 2, c"y"); printf(STDOUT, c"plain\n"); 1),
    "printf with STDOUT"    => () -> (print(STDOUT, "a "); printf(c"%d ", 1); print(STDOUT, "b "); printf(c"%d\n", 2); 1),
    "printf many args"      => () -> (printf(c"%d%d%d%d%d%d%d%d%d%d%d%d\n", 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2); printf(c"%d %f %d %f %s %lld\n", 1, 2.0, 3, 4.0, c"five", 6); 1),
    "print String vararg"   => () -> (print("a", "b", "c", "d"); println(); println("x", 1, 2, 3, "y"); 1),
    "println nothing"       => () -> (println(); println(nothing); println(missing); 1),
    "println Symbol/Float32" => () -> (println(:sym, ' ', 1.5f0, ' ', 0x1f, ' ', -3); 1),
    "show String/Char"      => () -> (show("a \"quoted\"\n string"); show('x'); show('\n'); show('λ'); println(); 1),
    "show escapes"          => () -> (show("tab\there \u00e9 \u2200 \e"); println(); 1),
    "show unprintable"      => () -> (show("a\u200bb\ue000\u00ad\U0001f600\u0378"); println(); 1),
    "@show String"          => () -> (s = "abc"; @show s; c = 'z'; @show c; 1),
    "big output"            => () -> (for i in 1:2000; print(i, ' '); end; println(); 1),
    ]; broken = ("stderr",))
end
