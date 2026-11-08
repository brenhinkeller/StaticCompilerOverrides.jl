# Logging (`@warn`, `@info`, `@error`) without the logging machinery of Base.
#
# The macros of Julia look up the current logger (a scoped value, or the global logger, which has the sink that the user chose),
# ask it whether the message is to be shown (through `invokelatest`, as the logger can be defined later than the code), and
# give the message to it. None of that is a thing for a program that is compiled: the logger is not known, and it has to be
# the same for the whole program. So the logger here is one: messages of the level `Info` and above are written to the
# standard error as the default logger of Julia writes them to something that is not a terminal (`┌ Warning: message`, the keywords
# as `│   key = value`, and the file and line); `@debug` messages are not written (as in Julia, without `JULIA_DEBUG`).
# The macros decide this when the program is compiled, so the code of the messages of a lower level is not in the binary.
# Not kept: `maxlog`, the `_module` and `group` of messages, the colors.

using Base.CoreLogging: AbstractLogger, LogLevel, Info, Warn, Error

"The logger of compiled programs: writes to the standard error."
struct StaticLogger <: AbstractLogger end

@device_override Base.CoreLogging.current_logger_for_env(level::LogLevel, group, _module) =
    level.level >= Info.level ? StaticLogger() : nothing

Base.CoreLogging.shouldlog(::StaticLogger, level, _module, group, id) = true
Base.CoreLogging.min_enabled_level(::StaticLogger) = Info

# the file of a message in the library of Julia is shown with the directory of the library of the machine that runs it
@device_override Base.fixup_stdlib_path(path::String) = path

level_label(level::LogLevel) = level >= Error ? "Error" : level >= Warn ? "Warning" : "Info"

function Base.CoreLogging.handle_message(::StaticLogger, level::LogLevel, msg, _module, group, id, file, line; kwargs...)
    return write_log(level, msg, file, line, kwargs)
end

function write_log(level::LogLevel, msg, file, line, kwargs)
    print(STDERR, "┌ ", level_label(level), ": ", msg, "\n")
    log_keywords(STDERR, values(kwargs))
    print(STDERR, "└ @ ", file, ":", line, "\n")
    return nothing
end

# (Base's version has a `try` that reports an error of the logger with another message, which is a lot of code for nothing)
@device_override Base.CoreLogging.handle_message_nothrow(::StaticLogger, level::LogLevel, msg, _module, group, id, file, line; kwargs...) =
    write_log(level, msg, file, line, kwargs)

# `│   key = value` for each of the keywords, as code that is made for their names (the types of the values differ)
@generated function log_keywords(io, kw::NamedTuple{names}) where {names}
    body = Expr(:block)
    for (i, name) in enumerate(names)
        name === :maxlog && continue
        push!(body.args, :(print(io, "│   ", $(QuoteNode(name)), " = ", getfield(kw, $i), "\n")))
    end
    push!(body.args, nothing)
    return body
end

# an error while making the message (the `catch` of the code of the macro): said, but not what it was
@device_override Base.CoreLogging.logging_error(::StaticLogger, level, _module, group, id, file, line, err, real::Bool = true) =
    print(STDERR, "┌ Error: Exception while generating log record\n└ @ ", file, ":", line, "\n")
