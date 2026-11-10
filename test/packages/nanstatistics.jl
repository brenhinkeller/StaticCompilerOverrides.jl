# NaNStatistics.jl: statistics that ignore NaNs, along dimensions, binning and sorting
using NaNStatistics

# (the result is an array of a size that is only known when the program runs)
# Reducing over several dimensions (`dims = (1, 2)`) is inferred as `Any` by NaNStatistics 1.0.2 (its generated functions call themselves,
# and inference gives up on the recursion), and so can't be compiled; later versions assert the type of the result (`::typeof(B)`).
const TUPLE_DIMS = ("nanmean tuple", "nansum tuple", "nanstd tuple", "nanvar tuple", "nansem tuple", "nanmedian tuple",
                    "nanskewness tuple", "nankurtosis tuple", "nanmad tuple", "nanpctile tuple")
const TUPLE_DIMS_INFERRED = only(Base.return_types(A -> nanmean(A; dims = (1, 2)), (Array{Float64, 3},))) !== Any
const NANSTATISTICS_BROKEN = TUPLE_DIMS_INFERRED ? () : TUPLE_DIMS

@testset "NaNStatistics.jl" begin
    @testset "Reductions that ignore NaNs" begin
        check_cases([
  "nanmax" => @opaque(() -> r6(nanmax(1.0, NaN) + nanmin(NaN, 2.0))),
  "nanadd" => @opaque(() -> r6(nanadd(1.0, NaN))),
  "nanmean 2arg"   => () -> r6(nanmean(dataN(), data())),
  "nanmaximum Int" => @opaque(() -> nanmaximum(collect(1:20))),
  "nanminimum Float32" => () -> r6(nanminimum(Float32.(dataN()))),
  "nanmean ranges" => @opaque(() -> r6(nanmean(1:10))),
  "nanmean view"   => () -> (x = dataN(); r6(nanmean(view(x, 3:30)))),
  "nanaad"         => () -> r6(nanaad(dataN())),
  "nanlogsumexp"   => () -> r6(nanlogsumexp(dataN())),
  "nanlogcumsumexp"=> () -> r6(sum(nanlogcumsumexp(dataN()))),
  "nanpctile"      => () -> r6(nanpctile(dataN(), 25)),
  "nanstandardize" => () -> r6(sum(filter(!isnan, nanstandardize(dataN())))),
  "nancovem"       => () -> r6(nancovem(dataN(), reverse(data()))),
        ], broken = NANSTATISTICS_BROKEN)
    end
    @testset "Along a dimension" begin
        check_cases([
  "nanmedian dim3" => () -> (m = reshape(dataN(), 5, 5, 2); r6(sum(nanmedian(m; dim = 3)))),
  "nanstd dims"    => () -> (m = reshape(dataN(), 10, 5); r6(sum(nanstd(m; dim = 2)))),
        ], broken = NANSTATISTICS_BROKEN)
    end
    @testset "Along several dimensions (a tuple of them)" begin
        check_cases([
  "nanmean tuple"  => () -> (m = reshape(dataN(), 10, 5); r6(sum(nanmean(m; dim = (1, 2))))),
  "nansum tuple"   => () -> (m = reshape(dataN(), 5, 5, 2); r6(sum(nansum(m; dim = (1, 2))))),
  "nanstd tuple"   => () -> (m = reshape(dataN(), 5, 5, 2); r6(sum(nanstd(m; dim = (1, 2))))),
  "nanvar tuple"   => () -> (m = reshape(dataN(), 5, 5, 2); r6(sum(nanvar(m; dim = (2, 3))))),
  "nansem tuple"   => () -> (m = reshape(dataN(), 5, 5, 2); r6(sum(nansem(m; dim = (1, 2))))),
  "nanmedian tuple" => () -> (m = reshape(dataN(), 5, 5, 2); r6(sum(nanmedian(m; dim = (1, 2))))),
  "nanskewness tuple" => () -> (m = reshape(dataN(), 5, 5, 2); r6(sum(nanskewness(m; dim = (1, 2))))),
  "nankurtosis tuple" => () -> (m = reshape(dataN(), 5, 5, 2); r6(sum(nankurtosis(m; dim = (1, 2))))),
  "nanmad tuple"   => () -> (m = reshape(dataN(), 5, 5, 2); r6(sum(nanmad(m; dim = (1, 2))))),
  "nanpctile tuple" => () -> (m = reshape(dataN(), 5, 5, 2); r6(sum(nanpctile(m, 30; dim = (1, 2))))),
        ], broken = NANSTATISTICS_BROKEN)
    end
    @testset "Binning" begin
        check_cases([
  "nanbinmedian"   => () -> (x = data(); y = dataN(); r6(sum(filter(!isnan, nanbinmedian(x, y, 0:5:30))))),
  "nanbinmean"     => () -> (x = data(); y = dataN(); r6(sum(filter(!isnan, nanbinmean(x, y, 0:5:30))))),
        ], broken = NANSTATISTICS_BROKEN)
    end
    @testset "Histograms" begin
        check_cases([
  "histcounts"     => () -> sum(histcounts(data(), 0:5:30)),
  "histcounts range" => () -> sum(histcounts(data(), 0:0.5:30)),
  "histcounts bins" => () -> sum(histcounts(data(), 0:5:30; )),
  "histcounts 2d"  => () -> sum(histcounts(data(), reverse(data()), 0:5:30, 0:5:30)),
  "histmean"       => () -> (c = histcounts(data(), 0:5:30); r6(histmean(c, 2.5:5:27.5))),
  "histstd"        => () -> (c = histcounts(data(), 0:5:30); r6(histstd(c, 2.5:5:27.5))),
  "histcountindices" => () -> sum(histcountindices(data(), 0:5:30)[1]),
        ], broken = NANSTATISTICS_BROKEN)
    end
    @testset "Sorting" begin
        check_cases([
  "nanargsort!"    => () -> (x = dataN(); i = collect(1:50); nanargsort!(i, x); sum(i .* (1:50))),
  "nansort!"       => () -> (x = dataN(); nansort!(x); r6(x[3])),
        ], broken = NANSTATISTICS_BROKEN)
    end
end
