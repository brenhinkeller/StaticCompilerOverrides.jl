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
    # the entropy of the system, at each call (`RandomDevice`, and `uuid4()` which uses it)
    check_cases([
        "RandomDevice: a byte"       => @opaque(() -> Int(rand(Random.RandomDevice(), UInt8) * 0 + 1)),
        "RandomDevice: two draws differ" => @opaque(() -> Int(rand(Random.RandomDevice(), UInt64) != rand(Random.RandomDevice(), UInt64))),
        "RandomDevice: Float64 and Bool" => @opaque(() -> (b = rand(Random.RandomDevice(), Bool); Int(0 <= rand(Random.RandomDevice()) < 1))),
        "RandomDevice: an array (more than 256 bytes)" => @opaque(() -> Int(length(unique(rand(Random.RandomDevice(), UInt8, 1000))) > 100)),
        "uuid4 without a generator"  => @opaque(() -> Int(uuid_version(uuid4())) + 10 * Int(uuid4() != uuid4())),
    ])
end
