
# TODO: Thin wrappers for tensorflow models.

function estimate_expression(input::ModelInput)
    if input.feature == :transcript
        return estimate_transcript_expression(input)
    elseif input.feature == :gene
        return estimate_gene_expression(input)
    elseif input.feature == :splicing
        return estimate_splicing_proportions(input)
    else
        error("Expression estimates for $(input.feature) not supported")
    end
end


function estimate_transcript_expression(input::ModelInput)
    num_samples, n = size(input.loaded_samples.x0_values)
    x0_log = log.(input.loaded_samples.x0_values)
    polee_py[:estimate_transcript_expression](
        input.loaded_samples.init_feed_dict, num_samples, n,
        input.loaded_samples.variables, x0_log)
end


function estimate_gene_expression(input::ModelInput)
    num_samples, n = size(input.loaded_samples.x0_values)

    num_features, gene_idxs, transcript_idxs, gene_ids, gene_names =
        gene_feature_matrix(input.ts, input.ts_metadata)

    p = sortperm(collect(zip(gene_idxs, transcript_idxs)))
    gene_idxs = gene_idxs[p]
    transcript_idxs = transcript_idxs[p]

    qx_feature_loc, qx_feature_scale = polee_py[:estimate_feature_expression](
        input.loaded_samples.init_feed_dict,
        input.loaded_samples.variables,
        num_samples, num_features, n,
        gene_idxs .- 1, transcript_idxs .- 1)

    return qx_feature_loc, qx_feature_scale, gene_ids, gene_names
end



function estimate_linear_regression(input::ModelInput)
    if input.feature == :transcript
        return estimate_transcript_linear_regression(input)
    elseif input.feature == :gene
        return estimate_gene_linear_regression(input)
    elseif input.feature == :splicing
        return estimate_splicing_linear_regression(input)
    else
        error("Linear regression for $(input.feature) not supported")
    end
end


"""
Build a 0/1 matrix encoding factor membership for each sample. First axis is
sample, second axis is factor index. If `include_bias` is true, include an
extra column of all ones.
"""
function build_linear_regression_design_matrix(input::ModelInput, include_bias::Bool=true)
    num_samples, n = size(input.loaded_samples.x0_values)
    factoridx = Dict{String, Int}()

    if include_bias
        factoridx["bias"] = 1
    end

    for factors in input.loaded_samples.sample_factors
        for factor in factors
            get!(factoridx, factor, length(factoridx) + 1)
        end
    end

    num_factors = length(factoridx)
    X = zeros(Float32, (num_samples, num_factors))
    for i in 1:num_samples
        for factor in input.loaded_samples.sample_factors[i]
            j = factoridx[factor]
            X[i, j] = 1
        end
    end
    if include_bias
        X[:, factoridx["bias"]] .= 1
    end

    return num_factors, factoridx, X
end


function write_linear_regression_effects(
        output_filename::String, input::ModelInput, factoridx, w_loc, w_scale, x_sigma_sq_mean)

    lower_credible = similar(w_loc)
    upper_credible = similar(w_loc)
    for i in 1:size(w_loc, 1)
        for j in 1:size(w_loc, 2)
            dist = Normal(w_loc[i, j], w_scale[i, j])

            lower_credible[i, j] = quantile(dist, input.credible_interval[1])
            upper_credible[i, j] = quantile(dist, input.credible_interval[2])
        end
    end

    write_effects(output_filename, factoridx,
                w_loc,
                w_scale,
                lower_credible,
                upper_credible,
                x_sigma_sq_mean,
                input.feature)
end


"""
Estimate linear regression over transcript expression.
"""
function estimate_transcript_linear_regression(input::ModelInput)
    num_factors, factoridx, X = build_linear_regression_design_matrix(input)
    num_samples, n = size(input.loaded_samples.x0_values)
    x0_log = log.(input.loaded_samples.x0_values)
    w_loc, w_scale, x_sigma_sq_mean = polee_py[:estimate_transcript_linear_regression](
        input.loaded_samples.init_feed_dict, input.loaded_samples.variables, x0_log, X)

    write_linear_regression_effects(
        input.output_filename === nothing ? "transcript-effects.db" : input.output_filename,
        input, factoridx, w_loc, w_scale, x_sigma_sq_mean)
end


function estimate_gene_linear_regression(input::ModelInput)
    # TODO:
    error("Linear regression for $(input.feature) not supported")
end


function estimate_splicing_linear_regression(input::ModelInput)
    sess = tf[:Session]()
    splice_lr_loc, splice_lr_scale = approximate_splicing_likelihood(input, sess)
    tf[:reset_default_graph]() # free up some memory
    sess[:close]()

    num_factors, factoridx, X = build_linear_regression_design_matrix(input)
    num_samples, n = size(input.loaded_samples.x0_values)
    x0_log = log.(input.loaded_samples.x0_values)

    w_loc, w_scale, x_sigma_sq_mean = polee_py[:estimate_splicing_linear_regression](
        input.loaded_samples.init_feed_dict,
        splice_lr_loc, splice_lr_scale,
        x0_log, X)

    # TODO: consider whether w should be converted to proportion scale (from log-ratio scale)
    # before writing.

    output_filename = input.output_filename === nothing ? "splicing-effects.db" : input.output_filename
    write_linear_regression_effects(
        output_filename, input, factoridx, w_loc, w_scale, x_sigma_sq_mean)

    # Compute the proportions and find credible intervals
    lower_quant = 0.01
    upper_quant = 0.99

    w_lower = similar(w_loc)
    w_upper = similar(w_loc)
    for i in 1:size(w_loc, 1), j in 1:size(w_loc, 2)
        dist = Normal(w_loc[i,j], w_scale[i,j])
        w_lower[i,j] = quantile(dist, lower_quant)
        w_upper[i,j] = quantile(dist, upper_quant)
    end

    x_prop_lower = logistic.(w_lower[2:end,:] .+ transpose(w_lower[1,:]))
    x_prop_upper = logistic.(w_upper[2:end,:] .+ transpose(w_upper[1,:]))

    x_span = x_prop_upper .- x_prop_lower
    x_prop_span = maximum(x_prop_lower, dims=1) .- minimum(x_prop_upper, dims=1)

    db = SQLite.DB(output_filename)
    SQLite.execute!(db, "drop table if exists splicing_prop_span")
    SQLite.execute!(
        db,
        """
        create table splicing_prop_span
        (splicing_num INT, span REAL)
        """)

    ins_stmt = SQLite.Stmt(db, "insert into splicing_prop_span values (?1, ?2)")
    SQLite.execute!(db, "begin transaction")
    for (feature_num, span) in enumerate(x_prop_span)
        SQLite.bind!(ins_stmt, 1, feature_num)
        SQLite.bind!(ins_stmt, 2, span)
        SQLite.execute!(ins_stmt)
    end
    SQLite.execute!(db, "end transaction")

    # Store credible intervals as proportions
    x_prop_lower = logistic.(w_lower .+ transpose(w_lower[1,:]))
    x_prop_upper = logistic.(w_upper .+ transpose(w_upper[1,:]))

    # Write a table recording credible intervals for proportions
    SQLite.execute!(db, "drop table if exists splicing_prop_credible_interval")
    SQLite.execute!(
        db,
        """
        create table splicing_prop_credible_interval
        (splicing_num INT, factor TEXT, p_lower REAL, p_upper REAL)
        """)

    ins_stmt = SQLite.Stmt(db, "insert into splicing_prop_credible_interval values (?1, ?2, ?3, ?4)")
    SQLite.execute!(db, "begin transaction")
    for factor = sort(collect(keys(factoridx)))
        i = factoridx[factor]
        for j in 1:size(w_lower, 2)
            SQLite.bind!(ins_stmt, 1, j)
            SQLite.bind!(ins_stmt, 2, factor)
            SQLite.bind!(ins_stmt, 3, x_prop_lower[i, j])
            SQLite.bind!(ins_stmt, 4, x_prop_upper[i, j])
            SQLite.execute!(ins_stmt)
        end
    end
    SQLite.execute!(db, "end transaction")
end


function estimate_mixture(input::ModelInput)
    if input.feature == :transcript
        return estimate_transcript_mixture(input)
    else
        error("Expression estimates for $(input.feature) not supported")
    end
end


function estimate_pca(input::ModelInput)
    if input.feature == :transcript
        return estimate_transcript_pca(input)
    elseif input.feature == :gene
        return estimate_gene_pca(input)
    elseif input.feature == :splicing
        return estimate_splicing_pca(input)
    else
        error("Expression estimates for $(input.feature) not supported")
    end
end


function estimate_transcript_pca(input::ModelInput)
    num_samples, n = size(input.loaded_samples.x0_values)
    num_pca_components = Int(get(input.parsed_args, "num-components", 8))
    x0_log = log.(input.loaded_samples.x0_values)
    z, w = polee_py[:estimate_transcript_pca](
        input.loaded_samples.init_feed_dict, num_samples, n,
        input.loaded_samples.variables, x0_log, num_pca_components)

    if haskey(input.parsed_args, "output-pca-w") && input.parsed_args["output-pca-w"] !== nothing
        write_pca_w(input.parsed_args["output-pca-w"], input, w)
    end

    output_filename = input.output_filename !== nothing ?
        input.output_filename : "transcript-pca-estimates.csv"
    write_pca_z(output_filename, input, z)
end


function estimate_gene_pca(input::ModelInput)
    # TODO:
end


function estimate_splicing_pca(input::ModelInput)
    # TODO:
end


function estimate_tsne(input::ModelInput)
    if input.feature == :transcript
        return estimate_transcript_tsne(input)
    elseif input.feature == :gene
        return estimate_gene_tsne(input)
    elseif input.feature == :splicing
        return estimate_splicing_tsne(input)
    else
        error("Expression estimates for $(input.feature) not supported")
    end
end


function estimate_transcript_tsne(input::ModelInput)
    num_samples, n = size(input.loaded_samples.x0_values)
    num_pca_components = Int(get(input.parsed_args, "num-components", 8))
    batch_size = min(num_samples, input.parsed_args["batch-size"])
    use_neural_network = input.parsed_args["neural-network"]
    x0_log = log.(input.loaded_samples.x0_values)

    sess = tf[:Session]()

    x_loc_full, x_scale_full = polee_py[:estimate_transcript_expression](
        input.loaded_samples.init_feed_dict, num_samples, n,
        input.loaded_samples.variables, x0_log, sess)

    tf[:reset_default_graph]() # free up some memory
    sess[:close]()
    sess = tf[:Session]()

    z = polee_py[:estimate_tsne](
        x_loc_full, x_scale_full,
        input.loaded_samples.init_feed_dict,
        input.loaded_samples.variables, num_pca_components,
        batch_size, use_neural_network, sess)

    # print_knn_graph(
    #     "tsne-knn.csv", knn(5, z), input.loaded_samples.sample_names)

    # open("p.csv", "w") do output
    #     for i in 1:size(p, 1)
    #         for j in 1:size(p, 1)
    #             if j > 1
    #                 print(output, ",")
    #             end
    #             print(output, p[i, j])
    #         end
    #         println(output)
    #     end
    # end


    # open("q.csv", "w") do output
    #     for i in 1:size(q, 1)
    #         for j in 1:size(q, 1)
    #             if j > 1
    #                 print(output, ",")
    #             end
    #             print(output, q[i, j])
    #         end
    #         println(output)
    #     end
    # end


    if haskey(input.parsed_args, "output-pca-w") && input.parsed_args["output-pca-w"] !== nothing
        write_pca_w(input.parsed_args["output-pca-w"], input, w)
    end

    output_filename = input.output_filename !== nothing ?
        input.output_filename : "transcript-tsne-estimates.csv"
    write_pca_z(output_filename, input, z)
end


function estimate_gene_tsne(input::ModelInput)
    error("t-SNE estimates for genes not yet supported.")
end


function estimate_splicing_tsne(input::ModelInput)
    num_samples, n = size(input.loaded_samples.x0_values)
    num_pca_components = Int(get(input.parsed_args, "num-components", 8))
    batch_size = min(num_samples, input.parsed_args["batch-size"])
    use_neural_network = input.parsed_args["neural-network"]
    x0_log = log.(input.loaded_samples.x0_values)

    sess = tf[:Session]()
    x_loc_full, x_scale_full = approximate_splicing_likelihood(input, sess)
    tf[:reset_default_graph]() # free up some memory
    sess[:close]()
    sess = tf[:Session]()

    z = polee_py[:estimate_tsne](
        x_loc_full, x_scale_full,
        input.loaded_samples.init_feed_dict,
        input.loaded_samples.variables, num_pca_components,
        batch_size, use_neural_network, sess)

    if haskey(input.parsed_args, "output-pca-w") && input.parsed_args["output-pca-w"] !== nothing
        write_pca_w(input.parsed_args["output-pca-w"], input, w)
    end

    output_filename = input.output_filename !== nothing ?
        input.output_filename : "splicing-tsne-estimates.csv"
    write_pca_z(output_filename, input, z)
end


function estimate_transcript_mixture(input::ModelInput)
    num_samples, n = size(input.loaded_samples.x0_values)
    x0_log = log.(input.loaded_samples.x0_values)

    num_pca_components = Int(get(input.parsed_args, "num-components", 8))
    num_mix_components = Int(get(input.parsed_args, "num-mixture-components", 12))

    @show (num_pca_components, num_mix_components)

    component_probs, w, x = polee_py[:estimate_transcript_mixture](
        input.loaded_samples.init_feed_dict, num_samples, n,
        input.loaded_samples.variables, x0_log,
        num_mix_components, num_pca_components)

    output_filename = input.output_filename === nothing ?
        "component-membership.csv" : input.output_filename

    # write_component_membership_html(input, component_probs)
    write_component_membership_csv(output_filename, input, component_probs)

    if haskey(input.parsed_args, "output-pca-w") && input.parsed_args["output-pca-w"] !== nothing
        write_pca_w(input.parsed_args["output-pca-w"], input, w)
    end

    write_pca_x("pca-x.csv", input, x)
end


function estimate_knn(input::ModelInput)
    if input.feature == :transcript
        return estimate_transcript_knn(input)
    else
        error("Knn estimates for $(input.feature) not supported")
    end
end


function estimate_transcript_knn(input::ModelInput)
    num_samples, n = size(input.loaded_samples.x0_values)
    x0_log = log.(input.loaded_samples.x0_values)
    x_loc, x_scale = polee_py[:estimate_transcript_expression](
        input.loaded_samples.init_feed_dict, num_samples, n,
        input.loaded_samples.variables, x0_log)

    print_knn_graph("knn.csv", knn(5, x_loc), input.loaded_samples.sample_names)
end


function estimate_vae_mixture(input::ModelInput)
    if input.feature == :transcript
        return estimate_transcript_vae_mixture(input)
    else
        error("Expression estimates for $(input.feature) not supported")
    end
end


function estimate_transcript_vae_mixture(input::ModelInput)
    num_samples, n = size(input.loaded_samples.x0_values)
    x0_log = log.(input.loaded_samples.x0_values)

    num_pca_components = Int(get(input.parsed_args, "num-components", 8))
    num_mix_components = Int(get(input.parsed_args, "num-mixture-components", 12))

    component_probs = polee_py[:estimate_transcript_vae_mixture](
        input.loaded_samples.init_feed_dict, num_samples, n,
        input.loaded_samples.variables, x0_log,
        num_mix_components, num_pca_components)

    output_filename = input.output_filename === nothing ?
        "component-membership.csv" : input.output_filename

    # write_component_membership_html(input, component_probs)
    write_component_membership_csv(output_filename, input, component_probs)
end


function write_component_membership_csv(output_filename, input, component_probs)
    num_samples, num_components = size(component_probs)
    open(output_filename, "w") do output
        println(output, "sample,component,prob")
        for j in 1:num_samples
            for i in 1:num_components
                if component_probs[j, i] > 1e-5
                    println(
                        output,
                        input.loaded_samples.sample_names[j], ",",
                        i, ",", component_probs[j, i])
                end
            end
        end
    end
end


function write_pca_x(output_filename, input, x)
    num_samples, n = size(x)
    open(output_filename, "w") do output
        print(output, "transcript_id")
        for i in 1:num_samples
            print(output, ",", input.loaded_samples.sample_names[i])
        end
        println(output)

        for (j, t) in enumerate(input.ts)
            @assert j == t.metadata.id
            print(output, t.metadata.name)
            for i in 1:num_samples
                print(output, ",", x[i, j])
            end
            println(output)
        end
    end
end


function write_pca_w(output_filename, input, w)
    n, num_components = size(w)
    open(output_filename, "w") do output
        print(output, "transcript_id")
        for j in 1:num_components
            print(output, ",component", j)
        end
        println(output)

        for (i, t) in enumerate(input.ts)
            @assert i == t.metadata.id
            print(output, t.metadata.name)
            for j in 1:num_components
                print(output, ",", w[i, j])
            end
            println(output)
        end
    end
end


function write_pca_z(output_filename, input, z)
    num_samples, num_pca_components = size(z)
    open(output_filename, "w") do output
        print(output, "sample")
        for j in 1:num_pca_components
            print(output, ",component", j)
        end
        println(output)

        for (i, sample) in enumerate(input.loaded_samples.sample_names)
            print(output, sample)
            for j in 1:num_pca_components
                print(output, ",", z[i, j])
            end
            println(output)
        end
    end
end


function write_component_membership_html(input::ModelInput, component_probs)
    num_samples, num_components = size(component_probs)
    open("component_membership.html", "w") do output
        println(output,
            """
            <!html>
            <head><title>component assignment probabilities</title>
            <style>
            td {
                border: 1px solid;
            }
            </style>
            </head>
            <body>
            <table>
            """)

        println(output, "<tr>")
        println(output, "<td></td>")
        for i in 1:num_components
            println(output, "<td>", i, "</td>")
        end
        println(output, "</tr>")

        for j in 1:num_samples
            println(output, "<tr>")
            println(output, "<td>", input.loaded_samples.sample_names[j], "</td>")
            for i in 1:num_components
                if component_probs[j, i] > 1e-5
                    println(output, "<td>", component_probs[j, i], "</td>")
                else
                    println(output, "<td></td>")
                end
            end

            println(output, "</tr>")
        end

        println(output,
            """
            </table></body>
            """)
    end
end


"""
Super-simplistic k-nearest neighbors. Outputs a an array of tuples
representing the edges of the knn graph.
"""
function knn(k, X)
    # X is assumed to be shaped like [samples, dimensionality]
    num_samples, n = size(X)
    k = min(k, num_samples)
    distances = Array{Float32}(undef, num_samples)
    edges = Tuple{Int, Int}[]
    for i in 1:num_samples
        for j in 1:num_samples
            distances[j] = sum((X[i,:] .- X[j,:]).^2)
        end
        for v in sortperm(distances)[2:k+1]
            push!(edges, (i, v))
        end
    end

    return edges
end


function print_knn_graph(output_filename, edges, sample_names)
    open(output_filename, "w") do output
        println(output, "u,v")
        for (u,v) in edges
            println(output, sample_names[u], ",", sample_names[v])
        end
    end
end


const POLEE_MODELS = Dict(
    "expression"        => estimate_expression,
    "linear-regression" => estimate_linear_regression,
    "pca"               => estimate_pca,
    "tsne"              => estimate_tsne,
    "knn"               => estimate_knn,
    "mixture"           => estimate_mixture,
    "vae-mixture"       => estimate_vae_mixture,
)

# Whether each method supports mini-batching.
const BATCH_MODEL = Dict(
    "expression"        => false,
    "linear-regression" => false,
    "pca"               => false,
    "tsne"              => true,
    "knn"               => false,
    "mixture"           => false,
    "vae-mixture"       => false)
