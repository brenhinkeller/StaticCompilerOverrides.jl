# Data that the tests of packages use.

using Statistics, LinearAlgebra

data() = Float64[sin(i) * 3 + i / 10 for i in 1:50]
dataN() = (x = data(); x[7] = NaN; x[20] = NaN; x)
weights50() = Float64[1 + (i % 3) for i in 1:50]
