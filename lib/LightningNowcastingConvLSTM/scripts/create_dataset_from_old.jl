using DrWatson
@quickactivate

using HDF5, JLD2, MLUtils, Random, CodecZlib
using ImageFiltering

path = datadir("exp_raw", "nowcasting.h5")

fed = h5read(path, "FED")
lat = h5read(path, "lat")
lon = h5read(path, "lon")
time = h5read(path, "time")

fed = convert.(UInt8, fed * Float32(255))

fed = permutedims(fed[:, :, 1, :, :], (1, 2, 4, 3)) # WxHxTxN

train, val = splitobs(fed; at=.97)

function uint8_filter(chunk, k)
    chunk = chunk / Float32(255)
    res = imfilter(chunk, k)
    res .= max.(chunk, res)
    floor.(UInt8, min.(res * Float32(255), 255.f0))
end

function augment(rng, ds, n_empty=0)
    n = size(ds, 4)
    output = zeros(eltype(ds), size(ds)[1:3]..., size(ds, 4)*4 + n_empty)
    idx = shuffle(rng, axes(output, 4))
    for i in 0:3
        @info "rotating $i"
        output[:, :, :, idx[n*i+1:n*(i+1)]] = mapslices(Base.Fix2(rotr90, i), ds, dims=(1, 2))
    end
    output
end

function apply_gaussian_filter(ds::AbstractArray{T, N}, sigma=.9) where {T, N}
    K = ntuple(Returns(0), N - 2)
    k = Float32.(Kernel.gaussian((sigma, sigma, K...)))
    k ./= (k[0, 0] / .5)
    f = Base.Fix2(uint8_filter, k)
    f(ds)
    # MappedArray(ds, f)
end

function apply_bilinear_filter(ds::AbstractArray{T, N}) where {T, N}
    K = ntuple(Returns(1), N - 2)
    k_org = reshape([1 2 1; 2 4 2; 1 2 1], (3, 3, K...))
    k = centered(k_org / Float32(sum(k_org)))
    f = Base.Fix2(uint8_filter, k)
    f(ds)
    # MappedArray(ds, f)
end

function apply_permissive_filter(ds::AbstractArray{T, N}) where {T, N}
    K = ntuple(Returns(1), N - 2)
    k_org = reshape(
        [
            .05 .05 .05 .05 .05;
            .05 .10 .15 .10 .05;
            .05 .15   1 .15 .05;
            .05 .10 .15 .10 .05;
            .05 .05 .05 .05 .05;
        ],
        (5, 5, K...),
    )
    k = centered(Float32.(k_org))
    f = Base.Fix2(uint8_filter, k)
    f(ds)
end

N_X = 10

@info "Applying gaussian filters"

C_sigma = 2

dataset_x = apply_gaussian_filter(train[:, :, begin:N_X, :], C_sigma)
dataset_y_teaching = apply_gaussian_filter(train[:, :, N_X+1:end, :], C_sigma)
dataset_y = apply_gaussian_filter(train[:, :, N_X+1:end, :], C_sigma)

dataset_x = augment(Xoshiro(42), dataset_x, 2_000)
dataset_y = augment(Xoshiro(42), dataset_y, 2_000)
dataset_y_teaching = augment(Xoshiro(42), dataset_y_teaching, 2_000)


@info "number of samples for train: $(size(dataset_x, 4))"

@save datadir("exp_pro", "train.jld2") {compress=true} dataset_x dataset_y_teaching dataset_y lat lon time

dataset = augment(Xoshiro(42), val, 200)
dataset_x = apply_gaussian_filter(dataset[:, :, begin:N_X, :], C_sigma)
dataset_y = dataset[:, :, N_X+1:end, :]

@info "number of samples for validation: $(size(dataset, 4))"

@save datadir("exp_pro", "val.jld2") {compress=true} dataset dataset_x dataset_y lat lon time

