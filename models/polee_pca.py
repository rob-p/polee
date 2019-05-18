
import numpy as np
import tensorflow as tf
import tensorflow_probability as tfp
from tensorflow_probability import distributions as tfd
import sys
from tensorflow_probability import edward2 as ed
from polee_approx_likelihood import *
from polee_training import *


def estimate_transcript_pca(
        init_feed_dict, num_samples, n, vars, x_init,
        num_pca_components, use_posterior_mean=False):

    log_prior, x_bias, w, z, x_scale_softminus, x = \
        pca_model(num_samples, n, num_pca_components, x_init, np.log(1/n))

    # likelihood
    log_likelihood = rnaseq_approx_likelihood_from_vars(vars, x)
    tf.summary.scalar("log_prior", log_prior)
    tf.summary.scalar("log_likelihood", log_likelihood)
    log_posterior = log_likelihood + log_prior

    sess = tf.Session()

    # Train
    if use_posterior_mean:
        train(sess, -log_prior, init_feed_dict, 1000, 5e-2)
    else:
        train(
            sess, -log_posterior, init_feed_dict, 1000, 5e-2,
            var_list=tf.trainable_variables() + [x, x_scale_softminus])

    return (sess.run(z), sess.run(w))


def estimate_feature_pca(
        x_likelihood_loc, x_likelihood_scale, num_samples, num_features,
        num_pca_components, use_posterior_mean):

    log_prior, x_bias, w, z, x_scale_softminus, x = \
        pca_model(num_samples, num_features, num_pca_components, x_likelihood_loc, 0.0)

    log_likelihood = tf.reduce_sum(
        tfd.Normal(x_likelihood_loc, x_likelihood_scale).log_prob(x))
    log_posterior = log_likelihood + log_prior

    sess = tf.Session()

    # Train
    if use_posterior_mean:
        train(sess, -log_prior, {}, 1000, 5e-2)
    else:
        train(
            sess, -log_posterior, {}, 1000, 5e-2,
            var_list=tf.trainable_variables() + [x, x_scale_softminus])

    return (sess.run(z), sess.run(w))


def pca_model(num_samples, n, num_pca_components, x_init, x_bias_loc0):
    log_prior = 0.0

    # x_bias
    x_bias_scale0 = 8.0
    x_bias_prior = tfd.Normal(
        loc=tf.constant(x_bias_loc0, dtype=tf.float32),
        scale=tf.constant(x_bias_scale0, dtype=tf.float32),
        name="x_bias")

    x_bias = tf.Variable(
        # np.maximum(np.mean(x_init, 0), x_bias_loc0),
        np.mean(x_init, 0),
        dtype=tf.float32,
        name="x_bias")

    log_prior += tf.reduce_sum(x_bias_prior.log_prob(x_bias))

    τ = tf.nn.softplus(tf.Variable(0.0, name="tau"))
    τ_prior = tfd.HalfCauchy(0.0, 1.0)
    log_prior += τ_prior.log_prob(τ)
    tf.summary.scalar("tau", τ)

    # λ = tf.nn.softplus(tf.Variable(np.full(n, -3.0, dtype=np.float32), name="lambda"))
    λ = tf.nn.softplus(tf.Variable(
        np.full((n, num_pca_components), -3.0, dtype=np.float32), name="lambda"))

    λ_prior = tfd.HalfCauchy(0.0, τ)
    log_prior += tf.reduce_sum(λ_prior.log_prob(λ))
    tf.summary.histogram("lambda", λ)

    # w
    w_prior = tfd.Normal(
        loc=tf.constant(0.0, dtype=tf.float32),
        # scale=tf.constant(1.0, dtype=tf.float32),
        # scale=tf.expand_dims(λ, -1),
        scale=λ,
        name="w_prior")

    # w_prior = tfd.StudentT(
    #     loc=tf.constant(0.0, dtype=tf.float32),
    #     scale=tf.constant(0.001, dtype=tf.float32),
    #     df=10.0,
    #     name="w_prior")

    # w_prior = tfd.Horseshoe(scale=1.0, name="w_prior")

    w = tf.Variable(
        tf.zeros([n, num_pca_components]),
        # tf.random_normal([n, num_pca_components], stddev=0.1),
        dtype=tf.float32,
        name="w")

    # tf.summary.histogram("w", w)
    # tf.summary.histogram("w_prior", w_prior.log_prob(w))

    log_prior += tf.reduce_sum(w_prior.log_prob(w))
    # log_prior += tf.reduce_sum(tf.clip_by_value(w_prior.log_prob(w), -1e8, 1e8))

    # z
    z_prior = tfd.Normal(
        loc=tf.constant(0.0, dtype=tf.float32),
        scale=tf.constant(4.0, dtype=tf.float32),
        name="z_comp_dist")

    z = tf.Variable(
        # tf.zeros([num_samples, num_pca_components]),
-       tf.random_normal([num_samples, num_pca_components], stddev=0.1),
        dtype=tf.float32,
        name="z")

    # tf.summary.histogram("z", z)

    log_prior += tf.reduce_sum(z_prior.log_prob(z))

    # x_scale
    x_scale_prior = tfd.HalfCauchy(
        loc=0.0,
        scale=0.01,
        name="x_scale_prior")

    # x_scale_prior = tfd.InverseGamma(
    #     0.001, 0.001)

    x_scale_softminus = tf.Variable(
        tf.constant(-3.0, shape=[n], dtype=tf.float32),
        trainable=False,
        name="x_scale")
    x_scale = tf.nn.softplus(x_scale_softminus)
    # tf.summary.histogram("x_scale", x_scale)
    # x_scale = tf.Print(x_scale,
    #     [tf.reduce_min(x_scale), tf.reduce_max(x_scale)], "x_scale span")

    log_prior += tf.reduce_sum(x_scale_prior.log_prob(x_scale))

    # x
    x_pca = tf.matmul(z, w, transpose_b=True, name="x_pca")
    x_loc = tf.add(x_pca, x_bias, name="x_loc")

    # x_prior = tfd.MultivariateNormalDiag(
    #     loc=x_loc,
    #     scale_diag=x_scale,
    #     name="x_prior")

    x_prior = tfd.StudentT(
        loc=x_loc,
        scale=x_scale,
        df=1.0,
        name="x_prior")

    x = tf.Variable(
        x_init,
        dtype=tf.float32,
        trainable=False,
        name="x")

    # tf.summary.histogram("x", x)

    log_prior += tf.reduce_sum(x_prior.log_prob(x))

    # inspecting an unexpressed transcript
    # idx = 178794
    # tf.summary.scalar("x_scale[idx]", x_scale[idx])
    # tf.summary.histogram("x_loc[idx]", x_loc[:,idx])
    # tf.summary.histogram("x[idx]", x[:,idx])
    # tf.summary.histogram("w[idx]", w[idx,:])

    return log_prior, x_bias, w, z, x_scale_softminus, x
