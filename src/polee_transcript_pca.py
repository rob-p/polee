
import numpy as np
import tensorflow as tf
import tensorflow_probability as tfp
from tensorflow_probability import distributions as tfd
import sys
from tensorflow_probability import edward2 as ed
from polee_approx_likelihood import *
from polee_training import *


def estimate_transcript_pca(
        init_feed_dict, num_samples, n, vars, x0_log,
        num_pca_components):

    log_prior = 0.0

    # x_bias
    x_bias_loc0 = np.log(1/n)
    x_bias_scale0 = 4.0
    x_bias_prior = tfd.Normal(
        loc=tf.constant(x_bias_loc0, dtype=tf.float32),
        scale=tf.constant(x_bias_scale0, dtype=tf.float32),
        name="x_bias")

    x_bias = tf.Variable(
        np.maximum(np.mean(x0_log, 0), x_bias_loc0),
        dtype=tf.float32,
        name="x_bias")

    log_prior += tf.reduce_sum(x_bias_prior.log_prob(x_bias))

    # w
    w_prior = tfd.Normal(
        loc=tf.constant(0.0, dtype=tf.float32),
        scale=tf.constant(1.0, dtype=tf.float32),
        name="w_prior")

    w = tf.Variable(
        # tf.zeros([n, num_pca_components]),
-       tf.random_normal([n, num_pca_components], stddev=0.1),
        dtype=tf.float32,
        name="w")

    log_prior += tf.reduce_sum(w_prior.log_prob(w))

    # z
    z_prior = tfd.Normal(
        loc=tf.constant(0.0, dtype=tf.float32),
        scale=tf.constant(1.0, dtype=tf.float32),
        name="z_comp_dist")

    z = tf.Variable(
        tf.zeros([num_samples, num_pca_components]),
# -       tf.random_normal([num_samples, num_pca_components], stddev=0.1),
        dtype=tf.float32,
        name="z")

    log_prior += tf.reduce_sum(z_prior.log_prob(z))

    # x_scale
    # x_scale_prior = HalfCauchy(
    #     loc=0.0,
    #     scale=0.01,
    #     name="x_scale_prior")

    x_scale_prior = tfd.InverseGamma(
        0.001, 0.001)

    x_scale_softminus = tf.Variable(
        tf.constant(-3.0, shape=[n], dtype=tf.float32),
        trainable=False,
        name="x_scale")
    x_scale = tf.nn.softplus(x_scale_softminus)
    # x_scale = tf.Print(x_scale,
    #     [tf.reduce_min(x_scale), tf.reduce_max(x_scale)], "x_scale span")

    log_prior += tf.reduce_sum(x_scale_prior.log_prob(x_scale))

    # x
    x_pca = tf.matmul(z, w, transpose_b=True, name="x_pca")
    x_loc = tf.add(x_pca, x_bias, name="x_loc")

    x_prior = tfd.MultivariateNormalDiag(
        loc=x_loc,
        scale_diag=x_scale,
        name="x_prior")

    x = tf.Variable(
        x0_log,
        dtype=tf.float32,
        trainable=False,
        name="x")

    log_prior += tf.reduce_sum(x_prior.log_prob(x))

    # likelihood
    log_likelihood = rnaseq_approx_likelihood_from_vars(vars, x)
    log_posterior = log_likelihood + log_prior

    # Pre-train
    sess = tf.Session()
    train(sess, -log_prior, init_feed_dict, 1000, 5e-2)

    # Train
    train(
        sess, -log_posterior, init_feed_dict, 1000, 5e-2,
        var_list=tf.trainable_variables() + [x, x_scale_softminus])

    return (sess.run(z), sess.run(w))