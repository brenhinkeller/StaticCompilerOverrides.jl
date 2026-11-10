# `Printf` (`@sprintf`, `@printf` with an `IO`, `Printf.format`) of the standard library of Julia.
#
# It is written to be resolved when compiling: the format has the types of its specifiers, and
# `Printf.format` writes the arguments one specifier at a time. Except for how it finds the argument
# for a specifier, which is `args[argp]`, where `args` is a tuple of the arguments (of different types)
# and `argp` the number of the argument, as a value that is not known when compiling: it is only needed
# for the specifiers that take their width or precision from the arguments (`%*d`).
#
# So, for formats that have none of those, the methods below pair the specifiers with the arguments
# by recursing over both, and use the methods of Printf for a specifier and its argument as they are, so
# that what they write is the same.

using Printf: Printf

const DYNAMIC_FORMAT_ERROR = "format specifiers that take the width or precision from an argument (`*`) are not supported in compiled code"

# Write the literal text of `f` before its `i`th specifier (or after the last one), as Printf does:
# the `%` that is not part of a specifier is written as is, and is the first of `%%`.
@inline function copy_literal(buf, pos, f, i, escapechar)
    for j in f.substringranges[i]
        b = f.str[j]
        if !escapechar
            buf[pos] = b
            pos += 1
            escapechar = b === UInt8('%')
        else
            escapechar = false
        end
    end
    return pos, escapechar
end

# the arguments for the specifiers, one by one
format_specs(buf, pos, f, formats::Tuple, args::Tuple, i, escapechar) = throw(ArgumentError(DYNAMIC_FORMAT_ERROR))
format_specs(buf, pos, f, ::Tuple{}, ::Tuple{}, i, escapechar) = pos
function format_specs(buf, pos, f, formats::Tuple{Any,Vararg}, args::Tuple{Any,Vararg}, i, escapechar)
    spec = first(formats)
    (spec.dynamic_width || spec.dynamic_precision) && throw(ArgumentError(DYNAMIC_FORMAT_ERROR))
    pos = Printf.fmt(buf, pos, first(args), spec)
    pos, escapechar = copy_literal(buf, pos, f, i + 1, escapechar)
    return format_specs(buf, pos, f, Base.tail(formats), Base.tail(args), i + 1, escapechar)
end

@device_override function Printf.format(buf::Vector{UInt8}, pos::Integer, f::Printf.Format, args...)
    pos, escapechar = copy_literal(buf, pos, f, 1, false)
    return format_specs(buf, pos, f, f.formats, args, 1, escapechar)
end

# the length of the output of each specifier
plength_specs(formats::Tuple, args::Tuple) = throw(ArgumentError(DYNAMIC_FORMAT_ERROR))
plength_specs(::Tuple{}, ::Tuple{}) = 0
function plength_specs(formats::Tuple{Any,Vararg}, args::Tuple{Any,Vararg})
    spec = first(formats)
    (spec.dynamic_width || spec.dynamic_precision) && throw(ArgumentError(DYNAMIC_FORMAT_ERROR))
    return Base.checked_add(Printf.plength(spec, first(args)), plength_specs(Base.tail(formats), Base.tail(args)))
end

@device_override Printf.computelen(substringranges, formats, args) =
    Base.checked_add(sum(length, substringranges), plength_specs(formats, args))
