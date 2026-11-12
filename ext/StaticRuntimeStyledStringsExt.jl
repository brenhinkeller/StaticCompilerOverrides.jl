# Printing a styled string (`AnnotatedString`, `styled"..."`, `AnnotatedChar`) to a stream that has color.
#
# StyledStrings finds the face of a piece of text in `FACES.current[]`, a `ScopedValue` that holds a `Dict` of the faces that are set (an object of the Julia that compiles, which can change
# when the program runs), and asks the terminal (`Base.current_terminfo()`) what it can do. A program is made with the faces that there are when compiling (the theme and what has been added
# with `addface!`), as `theme_face`, a comparison with each name, and for a terminal that does what a modern one does (`xterm-256color`): italics, reverse, strikethrough, `dim`, and the
# underline of a color and style are not used (`Base.get_have_truecolor()` is asked when the program runs: see `color.jl`). `withfaces`,
# `addface!` and the file `faces.toml` of the user, when the program runs, are not supported.
module StaticRuntimeStyledStringsExt

using StaticRuntime: @device_override
using StyledStrings: StyledStrings, Face, SimpleColor, RGBTuple, FACES
using Base: AnnotatedString, AnnotatedChar, eachregion

## the faces of the theme, as they are when compiling

function face_expression(face::Face)
    fields = Any[QuoteNode(getfield(face, i)) for i in 1:fieldcount(Face)-1]
    return :($Face($(fields...), $(copy(face.inherit))))
end

# the face of a name, which is `Face()` for a name that is not a face (as `get(Face, faces, name)` is)
@generated function named_face(name::Symbol)
    names = sort!(collect(keys(FACES.current[])))
    chain = :($Face())
    for k in reverse(names)
        chain = :(name === $(QuoteNode(k)) ? $(face_expression(FACES.current[][k])) : $chain)
    end
    return chain
end
default_face() = named_face(:default)

@generated function ansi_4bit_color(name::Symbol)
    chain = :(nothing)
    for (k, v) in StyledStrings.ANSI_4BIT_COLORS
        chain = :(name === $(QuoteNode(k)) ? $v : $chain)
    end
    return chain
end

@generated function base_color(name::Symbol)
    chain = :(nothing)
    for (k, v) in FACES.basecolors
        chain = :(name === $(QuoteNode(k)) ? $(QuoteNode(v)) : $chain)
    end
    return chain
end

## faces (`theme.jl`, `faces.jl` of StyledStrings, with `FACES.current[]` replaced by `named_face`)

@device_override StyledStrings._mergedface(face::Symbol) = named_face(face)

# the face that an annotation has, of the kinds of values that it has (a `Face`, a name, a list of them). One method that looks at the type (a method for each would be a call that is
# decided when the program runs, for a value of the type `Any`)
function annotation_face(value)::Face
    value isa Face && return value
    value isa Symbol && return named_face(value)
    if value isa Vector{Symbol}
        face = Face()
        first = true
        for name in Iterators.reverse(value)
            face = first ? named_face(name) : merge(face, named_face(name))
            first = false
        end
        return face
    end
    if value isa Vector{Face}
        face = Face()
        first = true
        for v in Iterators.reverse(value)
            face = first ? v : merge(face, v)
            first = false
        end
        return face
    end
    if value isa Vector{Any}
        face = Face()
        first = true
        for v in Iterators.reverse(value)
            face = first ? annotation_face(v) : merge(face, annotation_face(v))
            first = false
        end
        return face
    end
    return Face()
end

@device_override function StyledStrings.getface(annotations::Vector{@NamedTuple{label::Symbol, value::Any}})
    combined = Face()
    isempty(annotations) && return default_face()
    first = true
    for ann in annotations
        ann.label === :face || continue
        f = annotation_face(ann.value)
        combined = first ? f : merge(combined, f)
        first = false
    end
    first && return default_face()
    isempty(combined.inherit) || (combined = merge(Face(), combined))
    return merge(default_face(), combined)
end
@device_override StyledStrings.getface(face::Face) = merge(default_face(), merge(Face(), face))
@device_override StyledStrings.getface(face::Symbol) = StyledStrings.getface(named_face(face))
@device_override StyledStrings.getface() = default_face()

@device_override function Base.merge(a::Face, b::Face)
    if isempty(b.inherit)
        aheight = a.height
        bheight = b.height
        abheight = if isnothing(bheight) aheight
        elseif isnothing(aheight) bheight
        elseif bheight isa Int bheight
        elseif aheight isa Int round(Int, aheight * bheight)
        else aheight * bheight end
        Face(if isnothing(b.font)          a.font          else b.font          end,
             abheight,
             if isnothing(b.weight)        a.weight        else b.weight        end,
             if isnothing(b.slant)         a.slant         else b.slant         end,
             if isnothing(b.foreground)    a.foreground    else b.foreground    end,
             if isnothing(b.background)    a.background    else b.background    end,
             if isnothing(b.underline)     a.underline     else b.underline     end,
             if isnothing(b.strikethrough) a.strikethrough else b.strikethrough end,
             if isnothing(b.inverse)       a.inverse       else b.inverse       end,
             a.inherit)
    else
        b_noinherit = Face(b.font, b.height, b.weight, b.slant, b.foreground, b.background,
                           b.underline, b.strikethrough, b.inverse, Symbol[])
        inherited = Face()
        first = true
        for fname in Iterators.reverse(b.inherit)
            f = named_face(fname)
            inherited = first ? f : merge(inherited, f)
            first = false
        end
        merge(a, merge(inherited, b_noinherit))
    end
end

## the terminal

const ANSI = StyledStrings.ANSI_STYLE_CODES

@device_override function StyledStrings.termcolor(io::IO, color::SimpleColor, category::Char)
    if category == '4'
        if color.value == :background || color.value == base_color(:background)
            return print(io, "\e[", category, "9m")
        elseif color.value == :foreground
            return print(io, "\e[47m")
        end
    elseif color.value == :foreground || color.value == base_color(:foreground)
        return print(io, "\e[", category, "9m")
    elseif category == '3' && color.value == :background
        return print(io, "\e[30m")
    end
    for _ in 1:StyledStrings.MAX_COLOR_FORWARDS
        color.value isa RGBTuple && break
        fg = named_face(color.value::Symbol).foreground
        isnothing(fg) && return
        color == fg && break
        color = fg
    end
    if color.value isa RGBTuple
        if Base.get_have_truecolor()
            StyledStrings.termcolor24bit(io, color.value, category)
        else
            StyledStrings.termcolor8bit(io, color.value, category)
        end
        return
    end
    ansi = ansi_4bit_color(color.value::Symbol)
    isnothing(ansi) && return
    print(io, "\e[")
    if category == '3' || category == '4'
        print(io, StyledStrings.ansi_4bit(ansi, category == '4'))
    elseif category == '5'
        print(io, "58;5;", ansi)
    end
    print(io, 'm')
end

# `==` of the underlines, which can be a tuple of the type `Tuple{<:Union{Nothing,SimpleColor},Symbol}` (not a concrete type: what is compared is looked up when the program runs)
function same_underline(a, b)
    if a isa Tuple{Nothing,Symbol}
        return b isa Tuple{Nothing,Symbol} && a[2] === b[2]
    elseif a isa Tuple{SimpleColor,Symbol}
        return b isa Tuple{SimpleColor,Symbol} && a[1] == b[1] && a[2] === b[2]
    elseif b isa Tuple
        return false
    end
    return a == b
end

@device_override function StyledStrings.termstyle(io::IO, face::Face, lastface::Face = default_face())
    face.foreground == lastface.foreground ||
        StyledStrings.termcolor(io, face.foreground, '3')
    face.background == lastface.background ||
        StyledStrings.termcolor(io, face.background, '4')
    face.weight == lastface.weight || begin
        if lastface.weight != :normal && face.weight != :normal
            print(io, ANSI.normal_weight)
        end
        print(io, if face.weight in (:medium, :semibold, :bold, :extrabold, :black)
                  ANSI.bold_weight
              elseif face.weight in (:semilight, :light, :extralight, :thin)
                  "\e[2m"
              else
                  ANSI.normal_weight
              end)
    end
    face.slant == lastface.slant ||
        print(io, ifelse(face.slant in (:italic, :oblique), ANSI.start_italics, ANSI.end_italics))
    same_underline(face.underline, lastface.underline) ||
        print(io, ifelse(face.underline !== false, ANSI.start_underline, ANSI.end_underline))
    face.strikethrough == lastface.strikethrough ||
        print(io, ifelse(face.strikethrough === true, ANSI.start_strikethrough, ANSI.end_strikethrough))
    face.inverse == lastface.inverse ||
        print(io, ifelse(face.inverse === true, ANSI.start_reverse, ANSI.end_reverse))
    nothing
end

## `styled"..."`: merging the annotations that are next to each other and the same (`annotatedstring_optimize!`, which looks each up in a `Dict` of a tuple that has an `Any`, with the hash of its type)

function same_face(a::Face, b::Face)
    return a.font == b.font && a.height === b.height && a.weight === b.weight && a.slant === b.slant &&
           a.foreground == b.foreground && a.background == b.background && same_underline(a.underline, b.underline) &&
           a.strikethrough === b.strikethrough && a.inverse === b.inverse && a.inherit == b.inherit
end

# the values that annotations have, which are the same if they are as far as it is known here (a value that is of another kind is the same only if it is the same object)
function same_value(a, b)
    a isa Symbol && return b isa Symbol && a === b
    a isa Face && return b isa Face && same_face(a, b)
    a isa String && return b isa String && a == b
    a isa Vector{Symbol} && return b isa Vector{Symbol} && a == b
    return a === b
end

@device_override function StyledStrings.StyledMarkup.annotatedstring_optimize!(s::AnnotatedString)
    length(s.annotations) <= 1 && return s
    i = 1
    while i <= length(s.annotations)
        ann = s.annotations[i]
        prev = 0
        for j in i-1:-1:1
            other = s.annotations[j]
            if other.label === ann.label && same_value(other.value, ann.value)
                prev = j
                break
            end
        end
        if prev > 0 && last(s.annotations[prev].region) + 1 == first(ann.region)
            old = s.annotations[prev]
            s.annotations[prev] = Base.RegionAnnotation((first(old.region):last(ann.region), old.label, old.value))
            deleteat!(s.annotations, i)
        else
            i += 1
        end
    end
    return s
end

## writing

# the face and the link of the text between two changes of the annotations. (`eachregion` of Base makes, for each, a vector of the annotations as `@NamedTuple{label::Symbol, value::Any}`: a tuple
# that has an `Any` is made when the program runs, so the regions are found here, in the same way, and the annotations that apply are looked at where they are.)
function region_face(annots, active::Vector{Int})
    isempty(active) && return default_face()
    combined = Face()
    first = true
    for i in active
        annots[i].label === :face || continue
        f = annotation_face(annots[i].value)
        combined = first ? f : merge(combined, f)
        first = false
    end
    first && return default_face()
    isempty(combined.inherit) || (combined = merge(Face(), combined))
    return merge(default_face(), combined)
end

function region_link(annots, active::Vector{Int})
    for i in active
        annots[i].label === :link && return string(annots[i].value)::String
    end
    return nothing
end

function write_regions(string_writer::F, buf::IOBuffer, str::AbstractString, annots, subregion::UnitRange{Int}) where {F <: Function}
    default = default_face()
    lastface::Face = default
    function region!(region::UnitRange{Int}, active::Vector{Int})
        face = region_face(annots, active)
        link = region_link(annots, active)
        !isnothing(link) && write(buf, "\e]8;;", link, "\e\\")
        StyledStrings.termstyle(buf, face, lastface)
        string_writer(buf, SubString(str, region))
        !isnothing(link) && write(buf, "\e]8;;\e\\")
        lastface = face
    end
    if !isempty(str) && !isempty(subregion)
        events = Base.annotation_events(str, annots, subregion)
        if isempty(events)
            region!(subregion, Int[])
        else
            active = Int[]
            pos = first(events).pos
            pos > first(subregion) && region!(thisind(str, first(subregion)):prevind(str, pos), Int[])
            for event in events
                if event.pos != pos
                    region!(pos:prevind(str, event.pos), copy(active))
                    pos = event.pos
                end
                if event.active
                    insert!(active, searchsortedfirst(active, event.index), event.index)
                else
                    deleteat!(active, searchsortedfirst(active, event.index))
                end
            end
            last(events).pos < nextind(str, last(subregion)) && region!(last(events).pos:thisind(str, last(subregion)), Int[])
        end
    end
    StyledStrings.termstyle(buf, default, lastface)
    return buf
end

function ansi_write_styled(string_writer::F, io::IO, s::AnnotatedString) where {F <: Function}
    if get(io, :color, false)::Bool
        buf = IOBuffer()
        write_regions(string_writer, buf, s.string, Base.annotations(s), firstindex(s):lastindex(s))
        write(io, take!(buf))
    else
        string_writer(io, s.string)
    end
end

function ansi_write_styled(string_writer::F, io::IO, s::SubString{<:AnnotatedString}) where {F <: Function}
    if get(io, :color, false)::Bool
        buf = IOBuffer()
        write_regions(string_writer, buf, s.string.string, Base.annotations(s.string), (firstindex(s):lastindex(s)) .+ s.offset)
        write(io, take!(buf))
    else
        string_writer(io, Base.unannotate(s))
    end
end

@device_override Base.AnnotatedDisplay.ansi_write(f::F, io::IO, s::Union{<:AnnotatedString, SubString{<:AnnotatedString}}) where {F <: Function} =
    ansi_write_styled(f, io, s)

@device_override function Base.AnnotatedDisplay.ansi_write(::typeof(write), io::IO, c::AnnotatedChar)
    if get(io, :color, false) == true
        StyledStrings.termstyle(io, StyledStrings.getface(c), default_face())
        bytes = write(io, c.char)
        StyledStrings.termstyle(io, default_face(), StyledStrings.getface(c))
        bytes
    else
        write(io, c.char)
    end
end

end
