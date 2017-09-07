# TODO: use Pkg.dir when we make this an actual package
unshift!(PyVector(pyimport("sys")["path"]), "/home/dcjones/prj/extruder/src")
@pyimport tensorflow as tf
@pyimport tensorflow.contrib.distributions as tfdist
@pyimport tensorflow.python.client.timeline as tftl
@pyimport edward as ed
@pyimport edward.models as edmodels
@pyimport rnaseq_approx_likelihood
@pyimport hmc2


function load_samples_from_specification(experiment_spec_filename, ts_metadata)
    experiment_spec = YAML.load_file(experiment_spec_filename)
    names = [entry["name"] for entry in experiment_spec]
    filenames = [entry["file"] for entry in experiment_spec]
    sample_factors = [get(entry, "factors", String[]) for entry in experiment_spec]
    num_samples = length(filenames)
    println("Read model specification with ", num_samples, " samples")

    (likapprox_musigma, likapprox_efflen, likapprox_As,
     likapprox_parent_idxs, likapprox_js, x0) = load_samples(filenames, ts_metadata)
    println("Sample data loaded")

    return (likapprox_musigma, likapprox_efflen,
            likapprox_As, likapprox_parent_idxs, likapprox_js,
            x0, sample_factors, names)
end


function load_samples(filenames, ts_metadata)
    musigma_tensors = []
    efflen_tensors = []
    x0_tensors = []
    node_parent_idxs_tensors = []
    node_js_tensors = []
    As_tensors = []

    for filename in filenames
        input = h5open(filename, "r")

        n = read(input["n"])

        mu = read(input["mu"])
        sigma = read(input["omega"])
        map!(exp, sigma, sigma)

        node_parent_idxs = read(input["node_parent_idxs"])
        node_js = read(input["node_js"])
        effective_lengths = read(input["effective_lengths"])
        @show filename
        @show effective_lengths[122776]

        As = inverse_hsb_matrices(node_parent_idxs, node_js)
        push!(As_tensors, As)

        # choose logit-normal mean (actually: not really the mean)
        y0 = Array{Float64}(n-1)
        x0 = Array{Float32}(n)
        for i in 1:n-1
            y0[i] = clamp(logistic(mu[i]), LIKAP_Y_EPS, 1 - LIKAP_Y_EPS)
        end
        t = HSBTransform(node_parent_idxs, node_js)
        hsb_transform!(t, y0, x0, Val{true})
        push!(x0_tensors, x0)

        tf_mu = tf.constant(mu)
        tf_sigma = tf.constant(sigma)
        tf_musigma = tf.stack([tf_mu, tf_sigma])
        tf_efflen = tf.constant(effective_lengths)
        push!(musigma_tensors, tf_musigma)
        push!(efflen_tensors, tf_efflen)
        push!(node_parent_idxs_tensors, node_parent_idxs)
        push!(node_js_tensors, node_js)
    end

    return (tf.stack(musigma_tensors), tf.stack(efflen_tensors),
            As_tensors, hcat(node_parent_idxs_tensors...),
            hcat(node_js_tensors...), tf.stack(x0_tensors))
end


#=
function load_samples(filenames, ts_metadata)
    n = nothing

    musigma_tensors = []
    y0_tensors = []

    # work vectors for simplex!
    work1 = Array{Float32}(0)
    work2 = Array{Float32}(0)
    work3 = Array{Float32}(0)
    work4 = Array{Float32}(0)
    work5 = Array{Float32}(0)

    for filename in filenames
        input = h5open(filename, "r")

        n_ = read(input["n"])
        if n == nothing
            n = n_
            work1 = Array{Float32}(n)
            work2 = Array{Float32}(n)
            work3 = Array{Float32}(n)
            work4 = Array{Float32}(n)
            work5 = Array{Float32}(n)
        elseif n != n_
            error("Prepare sample was run with different transcript annotations on some samples.")
        end

        μ = read(input["mu"])
        σ = read(input["sigma"])

        # check that the right gff file is being used
        gffhash = read(attrs(input["metadata"])["gffhash"])
        if !isempty(gffhash) && base64decode(gffhash) != ts_metadata.gffhash
            error(@sprintf("'%s' was generated using a different GFF3 file than the one provided", filename))
        end

        close(input)

        @assert length(μ) == n - 1
        @assert length(σ) == n - 1

        #tf_μ = tf.constant(PyVector(μ))
        #tf_σ = tf.constant(PyVector(σ))

        tf_μ = tf.constant(μ)
        tf_σ = tf.constant(σ)
        tf_μσ = tf.stack([tf_μ, tf_σ])
        push!(musigma_tensors, tf_μσ)

        # choose mean to be the initial values for y
        initial_values = Array{Float32}(n)
        simplex!(n, initial_values, work1, work2, work3, work4, work5, μ)
        map!(log, initial_values, initial_values)
        push!(y0_tensors, initial_values)

    end

    musigma = tf.stack(musigma_tensors)
    y0 = tf.stack(y0_tensors)

    return (n, musigma, y0)
end
=#


immutable ModelInput
    likapprox_musigma::PyCall.PyObject
    likapprox_efflen::PyCall.PyObject
    likapprox_As::Vector{PyCall.PyObject}
    likapprox_parent_idxs::Array
    likapprox_js::Array
    x0::PyCall.PyObject
    sample_factors::Vector{Vector{String}}
    sample_names::Vector{String}
    feature::Symbol
    ts::Transcripts
    ts_metadata::TranscriptsMetadata
    output_filename::Nullable{String}
    gene_db::SQLite.DB
end


function estimate(experiment_spec_filename, output_filename)

    # read info from experiment specification
    experiment_spec = YAML.load_file(experiment_spec_filename)
    names = [entry["name"] for entry in experiment_spec]
    filenames = [entry["file"] for entry in experiment_spec]
    sample_factors = [get(entry, "factors", String[]) for entry in experiment_spec]
    num_samples = length(filenames)

    # build design matrix
    factoridx = Dict{String, Int}()
    factoridx["bias"] = 1
    for factors in sample_factors
        for factor in factors
            get!(factoridx, factor, length(factoridx) + 1)
        end
    end

    num_factors = length(factoridx)
    X_ = zeros(Float32, (num_samples, num_factors))
    for i in 1:num_samples
        for factor in sample_factors[i]
            j = factoridx[factor]
            X_[i, j] = 1
        end
    end
    X_[:, factoridx["bias"]] = 1
    X = tf.constant(X_)

    # read likelihood approximations and choose initial values
    n, musigma_data, y0 = load_samples(filenames)

    w_mu0 = 0.0
    w_sigma0 = 0.01
    w_bias_sigma0 = 100.0

    b_sigma_alpha0 = 2.0
    b_sigma_beta0 = 2.0

    b_sigma_sq = edmodels.InverseGamma(
            tf.constant(b_sigma_alpha0, shape=[1, n]),
            tf.constant(b_sigma_beta0, shape=[1, n]))
    b_sigma = tf.sqrt(b_sigma_sq)

    B = edmodels.MultivariateNormalDiag(
            name="B",
            tf.zeros([num_samples, n]),
            tf.matmul(tf.ones([num_samples, 1]), b_sigma))

    w_sigma = tf.concat(
                  [tf.constant(w_bias_sigma0, shape=[1, n]),
                   tf.constant(w_sigma0, shape=[num_factors-1, n])], 0)
    W = edmodels.MultivariateNormalDiag(
            name="W", tf.constant(0.0, shape=[num_factors, n]), w_sigma)

    y = tf.add(tf.matmul(X, W), B)
    #y = tf.matmul(X, W)

    musigma = rnaseq_approx_likelihood.RNASeqApproxLikelihood(
                y=y, value=musigma_data)

    datadict = PyDict(Dict(musigma => musigma_data))
    sess = ed.get_session()

    # Sampling
    # --------
    #=
    samples = tf.concat([tf.expand_dims(y0, 0),
                         tf.zeros([iterations, num_samples, n])], axis=0)
    qy_params = tf.Variable(samples, trainable=false)
    qy = edmodels.Empirical(params=qy_params)

    inference = hmc2.HMC2(PyDict(Dict(y => qy)),
                          data=PyDict(Dict(musigma => musigma_data)))
    inference[:run](step_size=0.00001, n_steps=2, logdir="logs")
    =#

    # VI
    # --

    # Optimize MAP for a few iterations to find a good starting point for VI
    opt_iterations = 500
    #qw_map_param = tf.Variable(tf.random_normal([num_factors, n]))
    qw_map_param = tf.Variable(tf.fill([num_factors, n], 5.0))
    qw_map = edmodels.PointMass(params=qw_map_param)

    qb_map_param = tf.Variable(tf.random_normal([num_samples, n]))
    qb_map = edmodels.PointMass(params=qb_map_param)

    qb_sigma_sq_map_param = tf.Variable(tf.ones([1, n]))
    qb_sigma_sq_map = edmodels.PointMass(params=qb_sigma_sq_map_param)

    inference = ed.MAP(Dict(W => qw_map, B => qb_map,
                            b_sigma_sq => qb_sigma_sq_map),
                       data=datadict)
    #inference = ed.MAP(Dict(W => qw_map), data=datadict)
    inference[:run](n_iter=opt_iterations)

    @show sess[:run](qw_map_param)[:,69693]
    @show sess[:run](tf.reduce_min(qb_map_param))
    @show sess[:run](tf.reduce_mean(qb_map_param))
    @show sess[:run](tf.reduce_max(qb_map_param))
    # TODO: can I initialize in a way that facilitates convergence?
    # E.g. Start off with bias weight high and others low and go from there?

    # Now run VI starting from mu set to the MAP estimates
    vi_iterations = 500
    qw_mu = tf.Variable(sess[:run](qw_map_param))
    qw_sigma = tf.identity(tf.Variable(tf.fill([num_factors, n], 0.01)))
    qw = edmodels.MultivariateNormalDiag(name="qw", qw_mu, qw_sigma)

    qb_mu = tf.Variable(sess[:run](qb_map_param))
    qb_sigma = tf.identity(tf.Variable(tf.fill([num_samples, n], 0.01)))
    qb = edmodels.MultivariateNormalDiag(name="qb", qb_mu, qb_sigma)

    inference = ed.KLqp(Dict(W => qw, B => qb), data=datadict)
    #inference = ed.KLqp(Dict(W => qw), data=datadict)

    # TODO: experiment with making this more aggressive
    learning_rate = 1e-3
    beta1 = 0.7
    beta2 = 0.99
    optimizer = tf.train[:AdamOptimizer](learning_rate, beta1, beta2)
    inference[:run](n_iter=vi_iterations, optimizer=optimizer)

    # Trace
    run_options = tf.RunOptions(trace_level=tf.RunOptions[:FULL_TRACE])
    run_metadata = tf.RunMetadata()
    sess[:run](inference[:train], options=run_options,
               run_metadata=run_metadata)
    #sess[:run](inference[:loss], options=run_options,
               #run_metadata=run_metadata)

    tl = tftl.Timeline(run_metadata[:step_stats])
    ctf = tl[:generate_chrome_trace_format]()
    trace_out = pybuiltin(:open)("timeline.json", "w")
    trace_out[:write](ctf)
    trace_out[:close]()

    # Evaluate posterior means
    y = tf.add(tf.matmul(X, qw_mu), qb_mu)
    #y = tf.matmul(X, qw_mu)

    post_mean = sess[:run](tf.nn[:softmax](y, dim=-1))
    #post_mean = sess[:run](y)
    write_estimates("post_mean.csv", names, post_mean)

    # E-GEUV specific code: remove batch effects by zeroing out that part of the
    # design matrix.
    batch_effect_factor_pattern = r"LAB_"
    for (factor, idx) in factoridx
        if match(batch_effect_factor_pattern, factor) != nothing
            X_[:, idx] = 0
        end
    end
    Z = tf.constant(X_)
    y = tf.add(tf.matmul(Z, qw_mu), qb_mu)
    #y = tf.matmul(Z, qw_mu)

    post_mean = sess[:run](tf.nn[:softmax](y, dim=-1))
    #post_mean = sess[:run](y)
    write_estimates("post_mean_nobatch.csv", names, post_mean)

    write_effects("effects.csv", factoridx, sess[:run](qw_mu))
end


function write_effects_csv(filename, factoridx, W)
    n = size(W, 2)
    open(filename, "w") do output
        println(output, "factor,id,w")
        for factor = sort(collect(keys(factoridx)))
            idx = factoridx[factor]
            for j in 1:n
                @printf(output, "%s,%d,%e\n", factor, j, W[idx, j])
            end
        end
    end
end


function write_effects(output_filename, factoridx, W, sigma, feature)
    println("Writing regression results to ", output_filename)

    db = SQLite.DB(output_filename)

    SQLite.execute!(db, "drop table if exists effects")
    SQLite.execute!(db,
        """
        create table effects
        ($(feature)_num INT, factor TEXT, w REAL, sigma REAL)
        """)

    ins_stmt = SQLite.Stmt(db, "insert into effects values (?1, ?2, ?3, ?4)")

    SQLite.execute!(db, "begin transaction")
    n = size(W, 2)
    for factor = sort(collect(keys(factoridx)))
        idx = factoridx[factor]
        for j in 1:n
            SQLite.bind!(ins_stmt, 1, j)
            SQLite.bind!(ins_stmt, 2, factor)
            SQLite.bind!(ins_stmt, 3, W[idx, j])
            SQLite.bind!(ins_stmt, 4, sigma[j])
            SQLite.execute!(ins_stmt)
        end
    end
    SQLite.execute!(db, "end transaction")
end


function write_estimates(filename, names, est)
    n = size(est, 2)
    open(filename, "w") do output
        # TODO: where do we get the transcript names from?
        println(output, "name,id,tpm")
        for (i, name) in enumerate(names)
            for j in 1:n
                @printf(output, "%s,%d,%e\n", name, j, est[i, j])
            end
        end
    end
end
    # TODO:
    # There more I think about it, there really should be a Normal distribution
    # between y and musigma.

