# `rand`, `randn`, `seed!`: the numbers are not Julia's (the generator of the program is seeded from the system), so what is compared is what they have to satisfy.

@testset "Random numbers" begin
    check_cases([
    "rand"                  => () -> (rand(Int) == rand(Int) ? 0 : 1),
    "rand range"            => () -> (x = rand(1:10); 1 <= x <= 10 ? 1 : 0),
    "rand Float64"          => () -> (x = rand(); 0 <= x < 1 ? 1 : 0),
    "randn"                 => () -> (isfinite(randn()) ? 1 : 0),
    "rand array"            => () -> (v = rand(3); length(v) + (all(0 .<= v .< 1) ? 10 : 0)),
    "seed!"                 => () -> (Random.seed!(1); Int(rand(UInt64) >> 1)),
    ])
end
