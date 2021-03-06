
using HDF5
using PyCall

using DataStructures
using SparseArrays
include("../stick_breaking.jl")

@pyimport tensorflow as tf


logit(x) = log(x) - log(1 - x)

function main()
    inverse_hsb_op_module = tf.load_op_library("./hsb_ops.so")

    input = h5open(ARGS[1])
    n = read(input["n"])
    node_parent_idxs = read(input["node_parent_idxs"])
    node_js = read(input["node_js"])
    t = HSBTransform(node_parent_idxs, node_js)
    num_nodes = 2*n-1

    # arrays needed by tensorflow op
    left_child = fill(Int32(-1), num_nodes)
    right_child = fill(Int32(-1), num_nodes)
    for i in 2:num_nodes
        parent_idx = node_parent_idxs[i]
        if right_child[parent_idx] == -1
            right_child[parent_idx] = i - 1
        else
            left_child[parent_idx] = i - 1
        end
    end
    leaf_index = Int32[j-1 for j in node_js]

    # Testing
    xs = rand(Float32, n)
    clamp!(xs, eps(Float32), 1 - eps(Float32))
    xs ./= sum(xs)

    ys_true = Array{Float32}(undef, n-1)
    hsb_inverse_transform!(t, xs, ys_true)
    ys_logit_true = logit.(ys_true)

    sess = tf.InteractiveSession()
    #sess = tf.Session(config=tf.ConfigProto(
        #intra_op_parallelism_threads=4))
    ys = inverse_hsb_op_module[:inv_hsb](
        tf.expand_dims(tf.constant(xs), 0),
        tf.expand_dims(tf.constant(left_child), 0),
        tf.expand_dims(tf.constant(right_child), 0),
        tf.expand_dims(tf.constant(leaf_index), 0))
    ys_logit_tf = sess[:run](ys)[1,:]

    @show extrema(abs.(ys_logit_tf .- ys_logit_true))
    @show ys

    # test gradients
    grad = ones(Float32, n-1)
    backprop = inverse_hsb_op_module[:inv_hsb_grad](
        tf.expand_dims(tf.constant(grad), 0),
        ys,
        tf.expand_dims(tf.constant(left_child), 0),
        tf.expand_dims(tf.constant(right_child), 0),
        tf.expand_dims(tf.constant(leaf_index), 0))
    sess[:run](backprop)
end

main()


