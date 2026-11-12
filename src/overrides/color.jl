# Printing with color: `printstyled`, and the escape sequences of `Base.text_colors`.
#
# Base keeps the sequences in two `Dict`s (`text_colors`, `disable_text_style`), which are objects of the Julia that compiles, so `output_color_string` is written here with
# the sequences as constants: a chain of comparisons of the symbol (as for `namedtuple_get`), which for a color that is known when compiling is folded.
#
# Whether the standard output has color is not known when compiling, and a program that is not told is as `julia script.jl > file`: it has none. `Base.get_have_color()` (which
# Crayons, and so UnicodePlots, ask for what `get(io, :color, ...)` does not say) is `false`, and a stream has color when its context says so: `IOContext(STDOUT, :color => true)`.

const TEXT_COLORS = (
    :black => "\e[30m", :red => "\e[31m", :green => "\e[32m", :yellow => "\e[33m", :blue => "\e[34m", :magenta => "\e[35m", :cyan => "\e[36m", :white => "\e[37m",
    :light_black => "\e[90m", :light_red => "\e[91m", :light_green => "\e[92m", :light_yellow => "\e[93m", :light_blue => "\e[94m", :light_magenta => "\e[95m",
    :light_cyan => "\e[96m", :light_white => "\e[97m", :normal => "\e[0m", :default => "\e[39m", :bold => "\e[1m", :italic => "\e[3m", :underline => "\e[4m",
    :blink => "\e[5m", :reverse => "\e[7m", :hidden => "\e[8m", :nothing => "",
)
const DISABLE_TEXT_STYLE = (:bold => "\e[22m", :italic => "\e[23m", :underline => "\e[24m", :blink => "\e[25m", :reverse => "\e[27m", :hidden => "\e[28m",
                            :normal => "", :default => "", :nothing => "")

@generated function symbol_text(::Val{table}, name::Symbol, default::String) where {table}
    chain = :default
    for (key, value) in reverse(collect(getfield(@__MODULE__, table)))
        chain = :(name === $(QuoteNode(key)) ? $value : $chain)
    end
    return chain
end
# the sequence of a color (a name, or a number of the 256: `"\e[38;5;Nm"`), which is `:default` if there is none, as in Base
color_escape(color::Symbol) = symbol_text(Val(:TEXT_COLORS), color, "\e[39m")
color_escape(color::Int) = 0 <= color <= 255 ? string("\e[38;5;", color, "m") : "\e[39m"
disable_escape(color::Symbol) = symbol_text(Val(:DISABLE_TEXT_STYLE), color, "\e[39m")
disable_escape(color::Int) = "\e[39m"

@device_override function Base.output_color_string(buf::IOBuffer, str::String, @nospecialize(color::Union{Int, Symbol}),
        bold::Bool, italic::Bool, underline::Bool, blink::Bool, reverse::Bool, hidden::Bool)
    bold && color === :bold && (color = :nothing)
    italic && color === :italic && (color = :nothing)
    underline && color === :underline && (color = :nothing)
    blink && color === :blink && (color = :nothing)
    reverse && color === :reverse && (color = :nothing)
    hidden && color === :hidden && (color = :nothing)
    enable_ansi = string(color_escape(color), bold ? "\e[1m" : "", italic ? "\e[3m" : "", underline ? "\e[4m" : "", blink ? "\e[5m" : "", reverse ? "\e[7m" : "", hidden ? "\e[8m" : "")
    disable_ansi = string(hidden ? "\e[28m" : "", reverse ? "\e[27m" : "", blink ? "\e[25m" : "", underline ? "\e[24m" : "", bold ? "\e[22m" : "", italic ? "\e[23m" : "", disable_escape(color))
    first = true
    for line in eachsplit(str, '\n')
        first || print(buf, '\n')
        first = false
        isempty(line) && continue
        print(buf, enable_ansi, line, disable_ansi)
    end
    return takestring!(buf)
end

@device_override Base.get_have_color() = false
# Whether the terminal has 24-bit color is asked when the program runs, of the environment as Base asks it (`ttyhastruecolor`) except for the terminfo of the terminal: the variables `COLORTERM`, `VTE_VERSION`,
# `XTERM_VERSION`, `TERMINAL_PROGRAM`, `KONSOLE_*` and `TERM`. (A terminal that says only in its terminfo is taken to have 256 colors.)
@device_override function Base.get_have_truecolor()
    get(ENV, "COLORTERM", "") in ("truecolor", "24bit") && return true
    something(tryparse(Int, get(ENV, "VTE_VERSION", "")), 0) >= 3600 && return true
    (haskey(ENV, "XTERM_VERSION") || haskey(ENV, "KONSOLE_PROFILE_NAME") || haskey(ENV, "KONSOLE_DBUS_SESSION")) && return true
    get(ENV, "TERMINAL_PROGRAM", "") == "iTerm.app" && return true
    term = get(ENV, "TERM", "")
    return startswith(term, "linux") || startswith(term, "rxvt") || startswith(term, "st")
end

# `printstyled` of a stream, and without one (that is `stdout`). The method for a stream is Base's `printstyled(io::IO, msg...)`, which `printstyled(msg...)` here would replace (a method of our table
# is the one that is called, whatever the other methods are), so it is written out, as `print_implicit` is for `print`.
@device_override Base.printstyled(msg...; kwargs...) = printstyled_implicit(msg...; kwargs...)
printstyled_implicit(io::IO, msg...; bold::Bool=false, italic::Bool=false, underline::Bool=false, blink::Bool=false, reverse::Bool=false, hidden::Bool=false, color::Union{Int,Symbol}=:normal) =
    Base.with_output_color(print, color, io, msg...; bold=bold, italic=italic, underline=underline, blink=blink, reverse=reverse, hidden=hidden)
printstyled_implicit(msg...; kwargs...) = printstyled_implicit(STDOUT, msg...; kwargs...)

## Annotated strings
#
# Base prints an `AnnotatedString` with `ansi_write_`, which calls `ansi_write` (that StyledStrings has methods of, for the styles) in the world of the running task (`invoke_in_world`),
# which is a call that the program makes when it runs. A program is made with the methods that there are when compiling: the call is made directly.
@device_override Base.AnnotatedDisplay.ansi_write_(f::Function, io::IO, @nospecialize(x)) = Base.AnnotatedDisplay.ansi_write(f, io, x)
@device_override Base.AnnotatedDisplay.show_annot_(io::IO, @nospecialize(x)) = (Base.AnnotatedDisplay.show_annot(io, x); nothing)
@device_override Base.AnnotatedDisplay.show_annot_(io::IO, m::MIME, @nospecialize(x)) = (Base.AnnotatedDisplay.show_annot(io, m, x); nothing)

# `annotatedstring(xs...)` (what `styled"..."` with interpolation, `join`, `*` and `repeat` of annotated strings make) goes through the arguments with a loop over a tuple of values of different types, that asks `x isa
# SubString{<:AnnotatedString}` of each: with the type of the element not known, that makes a type when the program runs. It is a call for each argument (the type of each is known), and an annotation is made from
# its parts, as `(; label, value)` is not for a value of the type `Any`.
@device_override function Base.annotatedstring(xs...)
    isempty(xs) && return Base.AnnotatedString("")
    buf = IOBuffer()
    s = IOContext(buf, :color => true)
    annotations = Vector{Base.RegionAnnotation}()
    add_annotated!(s, buf, annotations, xs...)
    return Base.AnnotatedString(takestring!(buf), annotations)
end
add_annotated!(s, buf, annotations) = nothing
function add_annotated!(s, buf, annotations, x::Base.AnnotatedString, rest...)
    size = buf.size
    for annot in x.annotations
        push!(annotations, Base.RegionAnnotation((annot.region .+ size, annot.label, annot.value)))
    end
    print(s, x.string)
    add_annotated!(s, buf, annotations, rest...)
end
function add_annotated!(s, buf, annotations, x::SubString{<:Base.AnnotatedString}, rest...)
    size = buf.size
    for annot in x.string.annotations
        start, stop = first(annot.region), last(annot.region)
        if start <= x.offset + x.ncodeunits && stop > x.offset
            rstart = size + max(0, start - x.offset - 1) + 1
            rstop = size + min(stop, x.offset + x.ncodeunits) - x.offset
            push!(annotations, Base.RegionAnnotation((rstart:rstop, annot.label, annot.value)))
        end
    end
    print(s, Base.unannotate(x))
    add_annotated!(s, buf, annotations, rest...)
end
function add_annotated!(s, buf, annotations, x::Base.AnnotatedChar, rest...)
    size = buf.size
    for annot in x.annotations
        push!(annotations, Base.RegionAnnotation((1+size:1+size, annot.label, annot.value)))
    end
    print(s, x.char)
    add_annotated!(s, buf, annotations, rest...)
end
function add_annotated!(s, buf, annotations, x, rest...)
    print(s, x)
    add_annotated!(s, buf, annotations, rest...)
end
