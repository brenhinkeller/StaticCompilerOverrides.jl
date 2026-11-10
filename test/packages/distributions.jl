# Distributions.jl: densities, distribution functions, quantiles, moments, fitting and random numbers (from a generator that is given)
using Distributions

@testset "Distributions.jl" begin
    @testset "Normal" begin
        check_cases([
  "Normal pdf" => @opaque(() -> r6(pdf(Normal(1.0, 2.0), 0.5))),
  "Normal logpdf" => @opaque(() -> r6(logpdf(Normal(1.0, 2.0), 0.5))),
  "Normal cdf"        => () -> r6(cdf(Normal(1.0, 2.0), 0.5)),
  "Normal quantile" => @opaque(() -> r6(quantile(Normal(1.0, 2.0), 0.3))),
  "Normal mean/var" => @opaque(() -> (d = Normal(1.0, 2.0); r6(mean(d) + var(d) + std(d) + entropy(d)))),
  "Normal ccdf"       => () -> r6(ccdf(Normal(), 1.5)),
  "Normal mgf" => @opaque(() -> r6(mgf(Normal(0.1, 0.5), 0.3))),
        ])
    end
    @testset "Continuous univariate distributions" begin
        check_cases([
  "Uniform" => @opaque(() -> (d = Uniform(1.0, 3.0); r6(pdf(d, 2.0) + cdf(d, 1.5) + quantile(d, 0.7) + mean(d) + var(d)))),
  "Exponential" => @opaque(() -> (d = Exponential(2.0); r6(pdf(d, 1.0) + cdf(d, 1.0) + quantile(d, 0.5) + mean(d) + var(d)))),
  "Gamma pdf" => @opaque(() -> r6(pdf(Gamma(2.0, 1.5), 1.2))),
  "Gamma cdf"         => () -> r6(cdf(Gamma(2.0, 1.5), 1.2)),
  "Gamma quantile"    => () -> r6(quantile(Gamma(2.0, 1.5), 0.4)),
  "Beta pdf"          => () -> r6(pdf(Beta(2.0, 3.0), 0.3)),
  "Beta cdf"          => () -> r6(cdf(Beta(2.0, 3.0), 0.3)),
  "Beta quantile"     => () -> r6(quantile(Beta(2.0, 3.0), 0.3)),
  "Beta mean/var"     => () -> (d = Beta(2.0, 3.0); r6(mean(d) + var(d) + entropy(d))),
  "Cauchy" => @opaque(() -> (d = Cauchy(0.0, 2.0); r6(pdf(d, 1.0) + cdf(d, 1.0) + quantile(d, 0.7)))),
  "LogNormal"         => () -> (d = LogNormal(0.5, 0.8); r6(pdf(d, 1.0) + cdf(d, 1.0) + quantile(d, 0.7) + mean(d))),
  "Weibull"           => () -> (d = Weibull(1.5, 2.0); r6(pdf(d, 1.0) + cdf(d, 1.0) + quantile(d, 0.7) + mean(d))),
  "Laplace" => @opaque(() -> (d = Laplace(0.5, 2.0); r6(pdf(d, 1.0) + cdf(d, 1.0) + quantile(d, 0.7)))),
  "Logistic" => @opaque(() -> (d = Logistic(0.5, 2.0); r6(pdf(d, 1.0) + cdf(d, 1.0) + quantile(d, 0.7)))),
  "TDist"             => () -> (d = TDist(5.0); r6(pdf(d, 1.0) + cdf(d, 1.0) + quantile(d, 0.7))),
  "Chisq"             => () -> (d = Chisq(3.0); r6(pdf(d, 1.0) + cdf(d, 1.0) + quantile(d, 0.7))),
  "FDist"             => () -> (d = FDist(3.0, 5.0); r6(pdf(d, 1.0) + cdf(d, 1.0))),
        ])
    end
    @testset "Discrete distributions" begin
        check_cases([
  "Poisson"           => () -> (d = Poisson(3.5); r6(pdf(d, 2) + cdf(d, 2) + mean(d) + var(d))),
  "Poisson quantile"  => () -> quantile(Poisson(3.5), 0.7),
  "Binomial"          => () -> (d = Binomial(10, 0.3); r6(pdf(d, 2) + cdf(d, 2) + mean(d) + var(d))),
  "Geometric" => @opaque(() -> (d = Geometric(0.3); r6(pdf(d, 2) + cdf(d, 2) + mean(d)))),
  "Bernoulli" => @opaque(() -> (d = Bernoulli(0.3); r6(pdf(d, 1) + mean(d) + var(d)))),
  "Categorical"       => () -> (d = Categorical([0.2, 0.3, 0.5]); r6(pdf(d, 2) + mean(d) + entropy(d))),
  "DiscreteUniform" => @opaque(() -> (d = DiscreteUniform(1, 6); r6(pdf(d, 2) + mean(d) + var(d)))),
        ])
    end
    @testset "Truncated distributions and mixtures" begin
        check_cases([
  "Truncated Normal"  => () -> (d = truncated(Normal(0, 1), -1, 2); r6(pdf(d, 0.5) + cdf(d, 0.5) + mean(d))),
  "MixtureModel"      => () -> (d = MixtureModel([Normal(0, 1), Normal(3, 1)], [0.4, 0.6]); r6(pdf(d, 1.0) + cdf(d, 1.0) + mean(d))),
        ])
    end
    @testset "Multivariate distributions" begin
        check_cases([
  "MvNormal logpdf"   => () -> (d = MvNormal([0.0, 1.0], [2.0 0.3; 0.3 1.0]); r6(logpdf(d, [0.5, 0.5]))),
  "MvNormal mean"     => () -> (d = MvNormal([0.0, 1.0], [2.0 0.3; 0.3 1.0]); r6(sum(mean(d)) + sum(cov(d)))),
  # OPEN: this one is refused when the code of Distributions is not inlined and folded by the compiler, as under `--code-coverage` (the CI job of the packages does not use it): it needs
  # `getfield` with a name that is only known when the program runs, of fields of different types, and `hash` of a `Union` or `UnionAll` (see `src/runtime/types.jl`, `define_field_index!`,
  # and `src/objectid.jl`)
  "MvNormal diag"     => () -> (d = MvNormal([0.0, 1.0], [2.0, 1.0]); r6(pdf(d, [0.5, 0.5]))),
  "MvNormal rand"     => () -> (rng = Random.Xoshiro(1); d = MvNormal([0.0, 1.0], [2.0 0.3; 0.3 1.0]); r6(sum(rand(rng, d)))),
  "Dirichlet"         => () -> (d = Dirichlet([1.0, 2.0, 3.0]); r6(pdf(d, [0.2, 0.3, 0.5]) + sum(mean(d)))),
  "Multinomial"       => () -> (d = Multinomial(5, [0.2, 0.3, 0.5]); r6(pdf(d, [1, 2, 2]) + sum(mean(d)))),
        ])
    end
    @testset "Random numbers (from a generator that is given)" begin
        check_cases([
  "rand Normal"       => () -> (rng = Random.Xoshiro(1); r6(rand(rng, Normal(1.0, 2.0)))),
  "rand Gamma"        => () -> (rng = Random.Xoshiro(1); r6(rand(rng, Gamma(2.0, 1.5)))),
  "rand Beta"         => () -> (rng = Random.Xoshiro(1); r6(rand(rng, Beta(2.0, 3.0)))),
  "rand Poisson"      => () -> (rng = Random.Xoshiro(1); rand(rng, Poisson(3.5))),
  "rand Binomial"     => () -> (rng = Random.Xoshiro(1); rand(rng, Binomial(20, 0.3))),
  "rand Categorical"  => () -> (rng = Random.Xoshiro(1); rand(rng, Categorical([0.2, 0.3, 0.5]))),
  "rand Exponential"  => () -> (rng = Random.Xoshiro(1); r6(rand(rng, Exponential(2.0)))),
  "rand n"            => () -> (rng = Random.Xoshiro(1); r6(sum(rand(rng, Normal(), 100)))),
  "rand default"      => () -> r6(abs(rand(Normal())) * 0),
        ])
    end
    @testset "Likelihood and fitting" begin
        check_cases([
  "loglikelihood"     => () -> r6(loglikelihood(Normal(1.0, 2.0), data())),
  "logpdf vector"     => () -> r6(sum(logpdf.(Normal(1.0, 2.0), data()))),
  "fit Normal"        => () -> (d = fit(Normal, data()); r6(mean(d) + std(d))),
  "fit Exponential"   => () -> (d = fit(Exponential, abs.(data())); r6(mean(d))),
  "fit_mle Gamma"     => () -> (d = fit_mle(Gamma, abs.(data()) .+ 0.1); r6(shape(d) + scale(d))),
  "fit Uniform"       => () -> (d = fit(Uniform, data()); r6(minimum(d) + maximum(d))),
        ])
    end
    @testset "Properties of a distribution" begin
        check_cases([
  "kldivergence" => @opaque(() -> r6(kldivergence(Normal(0, 1), Normal(1, 2)))),
  "skewness/kurtosis" => @opaque(() -> (d = Gamma(2.0, 1.5); r6(skewness(d) + kurtosis(d)))),
  "median/mode"       => () -> (d = Gamma(2.0, 1.5); r6(median(d) + mode(d))),
  "params" => @opaque(() -> (d = Normal(1.0, 2.0); p = params(d); r6(p[1] + p[2]))),
  "insupport" => @opaque(() -> (d = Beta(2.0, 3.0); Int(insupport(d, 0.5)) + Int(insupport(d, 2.0)))),
        ])
    end
    @testset "Types of the arguments" begin
        check_cases([
  "Float32 Normal" => @opaque(() -> r6(Float64(pdf(Normal(1.0f0, 2.0f0), 0.5f0)))),
  "Normal Int args" => @opaque(() -> r6(pdf(Normal(1, 2), 0))),
        ])
    end
    @testset "Special functions" begin
        check_cases([
  "logsumexp"         => () -> r6(Distributions.StatsFuns.logsumexp([1.0, 2.0, 3.0])),
  "erf/erfc"          => () -> r6(Distributions.StatsFuns.normcdf(0.3) + Distributions.StatsFuns.normpdf(0.3)),
  "gamma_inc"         => () -> r6(Distributions.StatsFuns.gammacdf(2.0, 1.5, 1.2)),
  "betacdf"           => () -> r6(Distributions.StatsFuns.betacdf(2.0, 3.0, 0.3)),
        ])
    end
end
