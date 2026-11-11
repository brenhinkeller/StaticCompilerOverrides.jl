# What a compiled program needs to know about Dates when it is loaded: the tokens of a format (`DatePart{'y'}`, `Delim`, ...) are of types that differ by
# a letter, which inference merges into `DatePart` when it takes one out of the tuple of a `DateFormat` (as the message of an error in parsing a date does),
# so a call on one is made over these.
module StaticRuntimeDatesExt

using StaticRuntime: add_family_candidates!
using Dates: Dates

function __init__()
    letters = collect(keys(Dates.CONVERSION_SPECIFIERS))
    add_family_candidates!([Dates.DatePart{c} for c in letters]..., Dates.Delim{Char,1},
                             [Dates.Delim{String,n} for n in 2:8]...)
end

end
