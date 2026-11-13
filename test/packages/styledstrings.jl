# StyledStrings: styled strings (`styled"..."`, `AnnotatedString`, `AnnotatedChar`) written to a stream with and without color, with the faces of the theme, and the operations that make them. The escape
# sequences are compared with Julia's, in the environment that the tests run in (the colors with 24 bits are asked of it; the terminal is `xterm-256color`, which `runtests.jl` sets, as a terminal that has no italics is asked of its terminfo,
# which a program does not read: see `ext/StaticRuntimeStyledStringsExt.jl`).

using StyledStrings
const COLOR_OUT = IOContext(STDOUT, :color => true)

@testset "StyledStrings" begin
    @testset "written, with and without color" begin
        check_cases([
            "plain"            => () -> (s = styled"{red:hi} there"; println(STDOUT, s); length(s)),
            "length of parts"  => () -> (s = styled"{bold:ab}c{italic:de}"; length(s) + 10 * length(Base.annotations(s))),
            "interpolation"    => () -> (x = opaque(3); s = styled"{bold:n=$x} and {red:$(x + 1)}"; println(STDOUT, s); length(s)),
            "color red"        => () -> (print(COLOR_OUT, styled"{red:hi} there\n"); 0),
            "bold"             => () -> (print(COLOR_OUT, styled"a {bold:b} c\n"); 0),
            "nested"           => () -> (print(COLOR_OUT, styled"{bold:a {red:b} c}\n"); 0),
            "background"       => () -> (print(COLOR_OUT, styled"{(background=green):x} y\n"); 0),
            "theme faces"      => () -> (print(COLOR_OUT, styled"{warning:w} {error:e} {success:s} {info:i}\n"); 0),
            "emphasis"         => () -> (print(COLOR_OUT, styled"{emphasis:e} {shadow:s} {code:c} {region:r}\n"); 0),
            "inherit"          => () -> (print(COLOR_OUT, styled"{(foreground=blue, inherit=bold):x}\n"); 0),
            "annotatedstring"  => () -> (s = annotatedstring("a", styled"{red:b}", 'c'); print(COLOR_OUT, s, "\n"); length(s)),
            "sprint plain"     => () -> (s = sprint(print, styled"{red:hi}"); println(s); ncodeunits(s)),
            "sprint color"     => () -> (s = sprint(io -> print(IOContext(io, :color => true), styled"{red:hi}")); println(repr(s)); ncodeunits(s)),
            "println styled"   => () -> (println(styled"{red:hi}"); 0),
            "AnnotatedChar"    => () -> (c = AnnotatedChar('x', [(:face, :red)]); print(COLOR_OUT, c, "\n"); 0),
            "substring"        => () -> (s = styled"{red:hello} {bold:world}"; print(COLOR_OUT, SubString(s, 3, 8), "\n"); 0),
            "link"             => () -> (print(COLOR_OUT, styled"{link={https://x.org}:site}\n"); 0),
            "escape_string"    => () -> (print(STDOUT, escape_string(styled"{red:a\tb}"), "\n"); 0),
            "uppercase"        => () -> (print(COLOR_OUT, uppercase(styled"{red:abc}"), "\n"); 0),
            "join"             => () -> (print(COLOR_OUT, join([styled"{red:a}", styled"{bold:b}"], ", "), "\n"); 0),
            "printstyled"      => () -> (printstyled(COLOR_OUT, "x"; color = :red); printstyled(COLOR_OUT, styled"{bold:y}\n"); 0),
        ])
    end
    @testset "made and changed" begin
        check_cases([
            "concatenation"    => () -> (print(COLOR_OUT, styled"{red:a}" * styled"{bold:b}" * "c", "\n"); 0),
            "indexing"         => () -> (s = styled"{red:hello} {bold:world}"; print(COLOR_OUT, s[3:8], "\n"); print(COLOR_OUT, s[end], "\n"); 0),
            "repeat"           => () -> (print(COLOR_OUT, repeat(styled"{red:ab}", 3), "\n"); 0),
            "lowercase"        => () -> (print(COLOR_OUT, lowercase(styled"{red:ABC}"), "\n"); 0),
            "split"            => () -> (parts = split(styled"{red:a b} {bold:c}", ' '); print(COLOR_OUT, parts[2], "|", parts[3], "\n"); length(parts)),
            "replace"          => () -> (print(COLOR_OUT, replace(styled"{red:abc}", "b" => "X"), "\n"); 0),
            "hex color"        => () -> (print(COLOR_OUT, styled"{(foreground=#ff8800):x} {(background=#00ff88):y}\n"); 0),
            "underline etc"    => () -> (print(COLOR_OUT, styled"{underline:u} {strikethrough:s} {(inverse=true):i} {italic:t}\n"); 0),
            "face value"       => () -> (print(COLOR_OUT, styled"{$(StyledStrings.Face(foreground = :red, weight = :bold)):f}\n"); 0),
            "face by name var" => () -> (n = opaque(:error); print(COLOR_OUT, styled"{$n:e}\n"); 0),
            "annotations"      => () -> (s = styled"{bold:a}{red:b}"; a = Base.annotations(s); length(a) + 10 * first(a[1].region) + 100 * last(a[2].region)),
            "annotate!"        => () -> (s = Base.AnnotatedString("abc"); Base.annotate!(s, 1:2, :face, :red); print(COLOR_OUT, s, "\n"); 0),
            "AnnotatedIOBuffer" => () -> (io = Base.AnnotatedIOBuffer(); print(io, styled"{red:a}"); print(io, "b"); s = read(io, Base.AnnotatedString); print(COLOR_OUT, s, "\n"); 0),
            "width"            => () -> (textwidth(styled"{red:abc}") + length(styled"{red:é}")),
        ])
    end
    # `show` of an `AnnotatedString` (what `repr` writes: `AnnotatedString{String}("a", [(1:1, :face, :red)])`) shows annotations that are of the type `Any`, which needs the types when the program runs
    @testset "show of an annotated string" begin
        check_cases(["show" => () -> (show(STDOUT, styled"{red:hi}"); 0)]; broken = ("show",))
    end
end
