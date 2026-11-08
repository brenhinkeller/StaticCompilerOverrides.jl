# NaNStatistics.jl: statistics that ignore NaNs, along dimensions, binning and sorting
using NaNStatistics

# (the result is an array of a size that is only known when the program runs)
const NANSTATISTICS_BROKEN = ("nanmean tuple",)

@testset "NaNStatistics.jl" begin
    check_cases([
  "nanpctile"      => () -> r6(nanpctile(dataN(), 25)),
  "nanstandardize" => () -> r6(sum(filter(!isnan, nanstandardize(dataN())))),
  "nanaad"         => () -> r6(nanaad(dataN())),
  "nanlogsumexp"   => () -> r6(nanlogsumexp(dataN())),
  "nanlogcumsumexp"=> () -> r6(sum(nanlogcumsumexp(dataN()))),
  "nanbinmedian"   => () -> (x = data(); y = dataN(); r6(sum(filter(!isnan, nanbinmedian(x, y, 0:5:30))))),
  "nanbinmean"     => () -> (x = data(); y = dataN(); r6(sum(filter(!isnan, nanbinmean(x, y, 0:5:30))))),
  "nanargsort!"    => () -> (x = dataN(); i = collect(1:50); nanargsort!(i, x); sum(i .* (1:50))),
  "nansort!"       => () -> (x = dataN(); nansort!(x); r6(x[3])),
  "nancovem"       => () -> r6(nancovem(dataN(), reverse(data()))),
  "nanmax"         => () -> r6(nanmax(1.0, NaN) + nanmin(NaN, 2.0)),
  "nanadd"         => () -> r6(nanadd(1.0, NaN)),
  "histcounts"     => () -> sum(histcounts(data(), 0:5:30)),
  "histcounts range" => () -> sum(histcounts(data(), 0:0.5:30)),
  "histcounts bins" => () -> sum(histcounts(data(), 0:5:30; )),
  "histcounts 2d"  => () -> sum(histcounts(data(), reverse(data()), 0:5:30, 0:5:30)),
  "histmean"       => () -> (c = histcounts(data(), 0:5:30); r6(histmean(c, 2.5:5:27.5))),
  "histstd"        => () -> (c = histcounts(data(), 0:5:30); r6(histstd(c, 2.5:5:27.5))),
  "histcountindices" => () -> sum(histcountindices(data(), 0:5:30)[1]),
  "nanmedian dim3" => () -> (m = reshape(dataN(), 5, 5, 2); r6(sum(nanmedian(m; dim = 3)))),
  "nanstd dims"    => () -> (m = reshape(dataN(), 10, 5); r6(sum(nanstd(m; dim = 2)))),
    "nanmean 2arg"   => () -> r6(nanmean(dataN(), data())),
  "nanmean tuple"  => () -> (m = reshape(dataN(), 10, 5); r6(sum(nanmean(m; dim = (1, 2))))),
  "nanmaximum Int" => () -> nanmaximum(collect(1:20)),
  "nanminimum Float32" => () -> r6(nanminimum(Float32.(dataN()))),
  "nanmean ranges" => () -> r6(nanmean(1:10)),
  "nanmean view"   => () -> (x = dataN(); r6(nanmean(view(x, 3:30)))),
], broken = NANSTATISTICS_BROKEN)
end
