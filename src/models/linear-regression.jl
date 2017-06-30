
function estimate_linear_regression(input::ModelInput)

    if input.feature == :transcript
        qy_mu_value, qy_sigma_value =
            estimate_transcript_expression(input)
    elseif input.feature == :gene
        qy_mu_value, qy_sigma_value =
            estimate_gene_expression(input)
    elseif input.feature == :splicing
        qy_mu_value, qy_sigma_value =
            estimate_splicing_log_ratio(input)
    else
        error("Linear regression for $(feature)s not supported")
    end

    qy_mu    = tf.constant(qy_mu_value)
    qy_sigma = tf.nn[:softplus](tf.constant(qy_sigma_value))
    n = qy_mu[:get_shape]()[:as_list]()[2]
    num_samples = length(input.sample_names)

    # build design matrix
    # -------------------

    factoridx = Dict{String, Int}()
    factoridx["bias"] = 1
    for factors in input.sample_factors
        for factor in factors
            get!(factoridx, factor, length(factoridx) + 1)
        end
    end

    num_factors = length(factoridx)
    X_ = zeros(Float32, (num_samples, num_factors))
    for i in 1:num_samples
        for factor in input.sample_factors[i]
            j = factoridx[factor]
            X_[i, j] = 1
        end
    end
    X_[:, factoridx["bias"]] = 1
    X = tf.constant(X_)

    println("Sample data loaded")

    # model specification
    # -------------------

    # TODO: pass these in as parameters
    w_mu0 = 0.0
    w_sigma0 = 1.0
    w_bias_mu0 = log(1/n)
    w_bias_sigma0 = 10.0

    w_sigma = tf.concat(
                  [tf.constant(w_bias_sigma0, shape=[1, n]),
                   tf.constant(w_sigma0, shape=[num_factors-1, n])], 0)
    w_mu = tf.concat(
                  [tf.constant(w_bias_mu0, shape=[1, n]),
                   tf.constant(w_mu0, shape=[num_factors-1, n])], 0)

    W = edmodels.MultivariateNormalDiag(name="W", w_mu, w_sigma)

    y_sigma_mu0 = tf.constant(0.0, shape=[n])
    y_sigma_sigma0 = tf.constant(1.0, shape=[n])

    y_log_sigma = edmodels.MultivariateNormalDiag(y_sigma_mu0, y_sigma_sigma0)
    y_sigma = tf.exp(y_log_sigma)

    y_sigma_param = tf.matmul(tf.ones([num_samples, 1]),
                              tf.expand_dims(y_sigma, 0))

    # TODO: I'm not sure how to set this up with splicing in mind. There I want to do:
    #  r = y[i] / (y[i] + y[i+1]) for i in 1, 3, 5, ...
    #
    #  but now it's not clear what's to be done with qy_sigma
    #
    # Maybe logistic regression is what we want to do here, since we are
    # predicting 0-1 values.
    #

    mu = edmodels.MultivariateNormalDiag(tf.matmul(X, W),
                                         tf.add(y_sigma_param, qy_sigma))

    # inference
    # ---------

    println("Estimating...")

    # optimize over the full model
    sess = ed.get_session()

    map_iterations = 1000

    #qw_param = tf.Variable(tf.fill([num_factors, n], 0.0))
    #qw_param = tf.Variable(sess[:run](w_mu))
    qw_param = tf.Variable(w_mu)
    #qw_param = tf.Print(qw_param, [tf.reduce_min(qw_param),
                                   #tf.reduce_max(qw_param)], "W span")
    qw = edmodels.PointMass(params=qw_param)

    #qy_log_sigma_param = tf.Variable(sess[:run](w_sigma))
    qy_log_sigma_param = tf.Variable(tf.fill([n], 0.1))
    # qy_log_sigma_param = tf.nn[:softplus](tf.Variable(tf.fill([n], -1.0f0)))
    #qy_log_sigma_param = tf.Print(qy_log_sigma_param,
                              #[tf.reduce_min(qy_log_sigma_param),
                               #tf.reduce_max(qy_log_sigma_param)], "sigma span")
    qy_log_sigma = edmodels.PointMass(params=qy_log_sigma_param)


    inference = ed.MAP(Dict(W => qw, y_log_sigma => qy_log_sigma),
                       data=PyDict(Dict(mu => qy_mu)))

    #inference = ed.MAP(Dict(W => qw), data=datadict)

    #inference[:run](n_iter=map_iterations)

    #optimizer = tf.train[:MomentumOptimizer](1e-12, 0.99)
    optimizer = tf.train[:AdamOptimizer](0.1)
    inference[:run](n_iter=map_iterations, optimizer=optimizer)
    #inference[:run](n_iter=map_iterations)

    output_filename = isnull(input.output_filename) ?
        "effects.db" : get(input.output_filename)

    @time write_effects(output_filename, factoridx,
                        sess[:run](qw_param),
                        sess[:run](tf.exp(qy_log_sigma_param)),
                        input.feature)
end


EXTRUDER_MODELS["linear-regression"] = estimate_linear_regression


