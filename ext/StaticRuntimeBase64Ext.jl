# `base64encode` and `base64decode` of a string or of bytes, written out: Base64's are streams that wrap an `IO` of a type that is not known when compiling, and that
# write to it through methods that are looked up when the program runs. (`base64encode` of other values, and of a function that writes, are not supported.)
module StaticRuntimeBase64Ext

using StaticRuntime: @device_override
using Base64: Base64

const ENCODE = Vector{UInt8}("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
const DECODE = let table = fill(0xff, 256)
    for (i, c) in enumerate(ENCODE)
        table[Int(c)+1] = UInt8(i - 1)
    end
    table
end

function encode_bytes(data::AbstractVector{UInt8})
    n = length(data)
    out = Vector{UInt8}(undef, 4 * cld(n, 3))
    i = 1
    j = 1
    while i + 2 <= n
        b = (UInt32(data[i]) << 16) | (UInt32(data[i+1]) << 8) | UInt32(data[i+2])
        out[j] = ENCODE[Int((b >> 18) & 0x3f)+1]
        out[j+1] = ENCODE[Int((b >> 12) & 0x3f)+1]
        out[j+2] = ENCODE[Int((b >> 6) & 0x3f)+1]
        out[j+3] = ENCODE[Int(b & 0x3f)+1]
        i += 3
        j += 4
    end
    rest = n - i + 1
    if rest == 1
        b = UInt32(data[i]) << 16
        out[j] = ENCODE[Int((b >> 18) & 0x3f)+1]
        out[j+1] = ENCODE[Int((b >> 12) & 0x3f)+1]
        out[j+2] = UInt8('=')
        out[j+3] = UInt8('=')
    elseif rest == 2
        b = (UInt32(data[i]) << 16) | (UInt32(data[i+1]) << 8)
        out[j] = ENCODE[Int((b >> 18) & 0x3f)+1]
        out[j+1] = ENCODE[Int((b >> 12) & 0x3f)+1]
        out[j+2] = ENCODE[Int((b >> 6) & 0x3f)+1]
        out[j+3] = UInt8('=')
    end
    return String(out)
end

function decode_bytes(text::AbstractVector{UInt8})
    out = UInt8[]
    bits = UInt32(0)
    count = 0
    padding = 0
    for c in text
        (c == UInt8(' ') || c == UInt8('\t') || c == UInt8('\n') || c == UInt8('\r')) && continue
        if c == UInt8('=')
            padding += 1
            continue
        end
        padding == 0 || throw(ArgumentError("malformed base64 sequence"))
        v = DECODE[Int(c)+1]
        v == 0xff && throw(ArgumentError("malformed base64 sequence"))
        bits = (bits << 6) | UInt32(v)
        count += 1
        if count == 4
            push!(out, UInt8((bits >> 16) & 0xff), UInt8((bits >> 8) & 0xff), UInt8(bits & 0xff))
            bits = UInt32(0)
            count = 0
        end
    end
    if count == 2
        push!(out, UInt8((bits >> 4) & 0xff))
    elseif count == 3
        push!(out, UInt8((bits >> 10) & 0xff), UInt8((bits >> 2) & 0xff))
    elseif count == 1
        throw(ArgumentError("malformed base64 sequence"))
    end
    return out
end

@device_override Base64.base64encode(x::Union{String,SubString{String}}; context = nothing) = encode_bytes(codeunits(x))
@device_override Base64.base64encode(x::Vector{UInt8}; context = nothing) = encode_bytes(x)
@device_override Base64.base64decode(s::Union{String,SubString{String}}) = decode_bytes(codeunits(s))

end
