# Dates: `Date`, `DateTime`, `Time`, periods, parsing and formatting, compared with Julia (the formats are made when compiling, with the macro `dateformat"..."`: see the extension of this package for `Dates`).

@testset "Dates" begin
    const_format = dateformat"dd/mm/yyyy"
    check_cases([
        "construct and fields"    => () -> (d = Date(2020, 3, 15); year(d) * 10000 + month(d) * 100 + day(d)),
        "arithmetic"              => () -> (d = Date(2020, 2, 28) + Day(2); month(d) * 100 + day(d)),
        "difference"              => () -> Dates.value(Date(2021, 1, 1) - Date(2020, 1, 1)),
        "calendar functions"      => () -> dayofweek(Date(2024, 2, 29)) + isleapyear(2024) + dayofyear(Date(2024, 12, 31)),
        "DateTime"                => () -> (t = DateTime(2020, 1, 2, 3, 4, 5); hour(t) * 10000 + minute(t) * 100 + second(t)),
        "periods"                 => () -> Dates.value(Month(3) + Month(4)) + Dates.value(Day(5) * 2),
        "show"                    => () -> (println(Date(2020, 3, 15)); println(DateTime(2020, 1, 2, 3, 4, 5)); println(Time(10, 20, 30)); 0),
        "ranges"                  => () -> length(Date(2020, 1, 1):Day(1):Date(2020, 1, 31)),
        "names"                   => () -> (println(monthname(Date(2020, 3, 1)), dayname(Date(2020, 3, 1))); 0),
        "parse an ISO date"       => () -> (d = Date(any_value("2021-12-25")); year(d) + day(d)),
        "parse a date time"       => () -> (d = DateTime(any_value("2021-12-25T10:20:30")); hour(d) + minute(d)),
        "tryparse"                => () -> (d = tryparse(Date, any_value("2021-12-25")); d === nothing ? 0 : year(d)),
        "parse with a format"     => () -> (d = Date(any_value("25/12/2021"), const_format); year(d) * 10000 + month(d) * 100 + day(d)),
        "format with a format"    => () -> (println(Dates.format(Date(2021, 12, 25), const_format)); 0),
        "now and today"           => () -> (year(today()) > 2000) + (year(now()) > 2000),
        "unix2datetime"           => () -> year(unix2datetime(1.6e9)),
    ])
end

