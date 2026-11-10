# StatsBase.jl: weighted and unweighted statistics, correlations, ranks, counting, histograms, sampling with a generator that is given
using StatsBase

# (`summarystats` splats a `Vector` of a length that is only known when the program runs into a constructor)
const STATSBASE_BROKEN = ("summarystats",)

@testset "StatsBase.jl" begin
    @testset "Means, variances and spread" begin
        check_cases([
  "mean/var/std"      => () -> (x = data(); r6(mean(x) + var(x) + std(x))),
  "mean_and_var"      => () -> ((m, v) = mean_and_var(data()); r6(m + v)),
  "mean_and_std"      => () -> ((m, v) = mean_and_std(data()); r6(m + v)),
  "mean_and_cov"      => () -> ((m, c) = mean_and_cov(reshape(data(), 10, 5)); r6(sum(m) + sum(c))),
  "geomean/harmmean"  => () -> (x = abs.(data()) .+ 1; r6(geomean(x) + harmmean(x))),
  "genmean"           => () -> (x = abs.(data()) .+ 1; r6(genmean(x, 3))),
  "variation/sem"     => () -> (x = data(); r6(variation(x) + sem(x))),
  "mean dims"         => () -> r6(sum(mean(reshape(data(), 10, 5); dims = 2))),
  "cronbach-ish mean dims" => () -> r6(sum(mean(reshape(data(), 10, 5), Weights(weights50()[1:10]); dims = 1))),
  "genvar/totalvar"   => () -> (c = cov(reshape(data(), 10, 5)); r6(genvar(c) + totalvar(c))),
        ], broken = STATSBASE_BROKEN)
    end
    @testset "Weights and weighted statistics" begin
        check_cases([
  "weighted mean"     => () -> r6(mean(data(), Weights(weights50()))),
  "weighted var"      => () -> r6(var(data(), Weights(weights50()))),
  "weighted std fw"   => () -> r6(std(data(), FrequencyWeights(weights50()))),
  "ProbabilityWeights"=> () -> r6(var(data(), ProbabilityWeights(weights50()))),
  "AnalyticWeights"   => () -> r6(var(data(), AnalyticWeights(weights50()))),
  "weights ops"       => () -> (w1 = Weights(weights50()); r6(sum(w1) + length(w1))),
  "eweights"          => () -> r6(sum(with_logger(() -> eweights(10, 0.3), NullLogger()))), # (a warning that the default will change: with `--depwarn=yes` Julia writes it, a program does not)
  "uweights" => @opaque(() -> r6(sum(uweights(10)))),
  "fweights" => @opaque(() -> sum(fweights([1, 2, 3]))),
        ], broken = STATSBASE_BROKEN)
    end
    @testset "Moments" begin
        check_cases([
  "skewness"          => () -> r6(skewness(data())),
  "kurtosis"          => () -> r6(kurtosis(data())),
  "moment"            => () -> r6(moment(data(), 3)),
  "cumulant"          => () -> r6(StatsBase.moment(data(), 4, mean(data()))),
        ], broken = STATSBASE_BROKEN)
    end
    @testset "Quantiles, robust spread and summaries" begin
        check_cases([
  "weighted median"   => () -> r6(median(data(), Weights(weights50()))),
  "weighted quantile" => () -> r6(quantile(data(), Weights(weights50()), 0.3)),
  "mad"               => () -> r6(mad(data(); normalize = true)),
  "iqr"               => () -> r6(iqr(data())),
  "percentile"        => () -> r6(percentile(data(), 30)),
  "nquantile"         => () -> r6(sum(nquantile(data(), 4))),
  "quantile"          => () -> r6(quantile(data(), [0.1, 0.9])[2]),
  "summarystats"      => () -> (s = summarystats(data()); r6(s.mean + s.median + s.q25)),
  "describe-less fivenum" => () -> r6(sum(StatsBase.quantile(data(), [0, .25, .5, .75, 1]))),
        ], broken = STATSBASE_BROKEN)
    end
    @testset "Standardization" begin
        check_cases([
  "zscore"            => () -> r6(sum(zscore(data()))),
  "zscore mu sigma"   => () -> r6(sum(zscore(data(), 1.0, 2.0))),
  "ZScoreTransform"   => () -> (t = fit(ZScoreTransform, reshape(data(), 10, 5); dims = 1); r6(sum(StatsBase.transform(t, reshape(data(), 10, 5))))),
  "UnitRangeTransform"=> () -> (t = fit(UnitRangeTransform, reshape(data(), 10, 5); dims = 1); r6(sum(StatsBase.transform(t, reshape(data(), 10, 5))))),
  "standardize"       => () -> (t = fit(ZScoreTransform, data()); r6(sum(StatsBase.transform(t, data())))),
        ], broken = STATSBASE_BROKEN)
    end
    @testset "Correlation and covariance" begin
        check_cases([
  "cor"               => () -> r6(cor(data(), reverse(data()))),
  "cov"               => () -> r6(cov(data(), reverse(data()))),
  "cov matrix"        => () -> r6(sum(cov(reshape(data(), 10, 5)))),
  "cor matrix"        => () -> r6(sum(cor(reshape(data(), 10, 5)))),
  "scattermat"        => () -> r6(sum(scattermat(reshape(data(), 10, 5)))),
  "cov2cor"           => () -> (c = cov(reshape(data(), 10, 5)); r6(sum(cov2cor(c, sqrt.(diag(c)))))),
  "autocor"           => () -> r6(sum(autocor(data(), 0:5))),
  "autocov"           => () -> r6(sum(autocov(data(), 0:5))),
  "crosscor"          => () -> r6(sum(crosscor(data(), reverse(data()), 0:3))),
  "pacf"              => () -> r6(sum(pacf(data(), 1:4))),
  "spearman"          => () -> r6(corspearman(data(), reverse(data()))),
  "kendall"           => () -> r6(corkendall(data(), reverse(data()))),
        ], broken = STATSBASE_BROKEN)
    end
    @testset "Ranks" begin
        check_cases([
  "ranktie ordinal"   => () -> sum(ordinalrank(data())),
  "competerank"       => () -> sum(competerank(data())),
  "denserank"         => () -> sum(denserank(data())),
  "tiedrank"          => () -> r6(sum(tiedrank(data()))),
        ], broken = STATSBASE_BROKEN)
    end
    @testset "Counting and run lengths" begin
        check_cases([
  "countmap"          => () -> (m = countmap([i % 4 for i in 1:50]); m[1] + m[2]),
  "countmap strings"  => () -> (m = countmap(["a", "b", "a", "c", "a"]); m["a"]),
  "proportionmap"     => () -> (m = proportionmap([i % 4 for i in 1:50]); r6(m[1])),
  "counts"            => () -> sum(counts([i % 4 + 1 for i in 1:50])),
  "counts range"      => () -> sum(counts([i % 4 + 1 for i in 1:50], 1:4)),
  "addcounts!"        => () -> (d = Dict{Int,Int}(); addcounts!(d, [1, 2, 2, 3]); d[2]),
  "mode"              => () -> mode([1, 2, 2, 3, 3, 3]),
  "modes"             => () -> length(modes([1, 2, 2, 3, 3])),
  "rle"               => () -> ((v, c) = rle([1, 1, 2, 2, 2, 3]); sum(c)),
  "inverse_rle"       => () -> sum(inverse_rle([1, 2, 3], [2, 3, 1])),
  "indicatormat"      => () -> sum(indicatormat([1, 2, 3, 2], 3)),
  "indexmap"          => () -> StatsBase.indexmap(["a", "b", "a"])["b"],
  "midpoints"         => () -> r6(sum(StatsBase.midpoints(0:5:30))),
        ], broken = STATSBASE_BROKEN)
    end
    @testset "Entropy and divergences" begin
        check_cases([
  "entropy"           => () -> r6(entropy([0.2, 0.3, 0.5])),
  "entropy base"      => () -> r6(entropy([0.2, 0.3, 0.5], 2)),
  "crossentropy"      => () -> r6(crossentropy([0.2, 0.3, 0.5], [0.3, 0.3, 0.4])),
  "kldivergence"      => () -> r6(kldivergence([0.2, 0.3, 0.5], [0.3, 0.3, 0.4])),
  "renyientropy"      => () -> r6(renyientropy([0.2, 0.3, 0.5], 2)),
  "gkldiv/counteq"    => () -> counteq(round.(Int, data()), round.(Int, reverse(data()))),
        ], broken = STATSBASE_BROKEN)
    end
    @testset "Histograms and empirical distribution functions" begin
        check_cases([
  "histogram fit"     => () -> (h = fit(Histogram, data(), 0:5:30); sum(h.weights)),
  "histogram edges"   => () -> (h = fit(Histogram, data(); nbins = 5); sum(h.weights)),
  "histogram 2d"      => () -> (h = fit(Histogram, (data(), reverse(data())), (0:5:30, 0:5:30)); sum(h.weights)),
  "histogram normalize"=> () -> (h = normalize(fit(Histogram, data(), 0:5:30)); r6(sum(h.weights))),
  "ecdf"              => () -> (e = ecdf(data()); r6(e(3.0))),
  "ecdf weights"      => () -> (e = ecdf(data(); weights = Weights(weights50())); r6(e(3.0))),
        ], broken = STATSBASE_BROKEN)
    end
    @testset "Sampling (with a generator that is given)" begin
        check_cases([
  "sample"            => () -> (rng = Random.Xoshiro(1); sample(rng, 1:100)),
  "sample n"          => () -> (rng = Random.Xoshiro(1); sum(sample(rng, 1:100, 10))),
  "sample noreplace"  => () -> (rng = Random.Xoshiro(1); sum(sample(rng, 1:100, 10; replace = false))),
  "sample weights"    => () -> (rng = Random.Xoshiro(1); sum(sample(rng, 1:5, Weights([1.0, 2, 3, 4, 5]), 10))),
  "sample weights nr" => () -> (rng = Random.Xoshiro(1); sum(sample(rng, 1:5, Weights([1.0, 2, 3, 4, 5]), 3; replace = false))),
  "sample! "          => () -> (rng = Random.Xoshiro(1); a = zeros(Int, 5); sample!(rng, 1:10, a); sum(a)),
  "wsample"           => () -> (rng = Random.Xoshiro(1); wsample(rng, [1, 2, 3], [0.2, 0.3, 0.5])),
  "alias sampler"     => () -> (rng = Random.Xoshiro(1); s = StatsBase.alias_sample!(rng, [1, 2, 3], Weights([0.2, 0.3, 0.5]), zeros(Int, 10)); sum(s)),
  "shuffle-ish samplepair" => () -> (rng = Random.Xoshiro(1); samplepair(rng, 10)[1] > 0),
        ], broken = STATSBASE_BROKEN)
    end
    @testset "Distances and errors" begin
        check_cases([
  "rmsd"              => () -> r6(rmsd(data(), reverse(data()))),
  "msd/meanad"        => () -> r6(msd(data(), reverse(data())) + meanad(data(), reverse(data()))),
  "maxad"             => () -> r6(maxad(data(), reverse(data()))),
  "psnr"              => () -> r6(psnr(data(), reverse(data()), 10.0)),
  "predict-free L2dist" => () -> r6(L2dist(data(), reverse(data()))),
  "sqL2dist"          => () -> r6(sqL2dist(data(), reverse(data()))),
        ], broken = STATSBASE_BROKEN)
    end
end
