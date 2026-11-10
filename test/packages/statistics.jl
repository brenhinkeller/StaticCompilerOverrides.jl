# Statistics: means, variances, medians, quantiles, covariance and correlation of arrays that the program makes, compared with Julia (to 6 digits). (StatsBase.jl is in `statsbase.jl`.)

@testset "Statistics" begin
    x() = Float64[opaque(3), 1, 4, 1, 5, 9, 2, 6]
    y() = Float64[opaque(2), 7, 1, 8, 2, 8, 1, 8]
    check_cases([
        "mean"                     => () -> r6(mean(x())),
        "mean of a function"       => () -> r6(mean(abs2, x())),
        "var and std"              => () -> (v = x(); r6(var(v) + std(v))),
        "var with the mean given"  => () -> (v = x(); r6(var(v; mean = 3.0, corrected = false))),
        "median"                   => () -> r6(median(x())),
        "quantile"                 => () -> r6(quantile(x(), 0.3) + quantile(x(), [0.1, 0.9])[2]),
        "cov and cor"              => () -> r6(cov(x(), y()) + cor(x(), y())),
        "mean along a dimension"   => () -> r6(sum(mean(reshape(x(), 4, 2); dims = 1))),
        "cov of a matrix"          => () -> r6(sum(cov(reshape(vcat(x(), y()), 8, 2)))),
        "middle"                   => () -> r6(middle(x())),
    ])
end
