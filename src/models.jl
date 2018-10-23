
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
    # polee_py[:estimate_transcript_expression_dropout](
        input.loaded_samples.init_feed_dict, num_samples, n,
        input.loaded_samples.variables, x0_log)
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
    num_pca_components = Int(get(input.parsed_args, "num-pca-components", 8))
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
    num_pca_components = Int(get(input.parsed_args, "num-pca-components", 8))
    batch_size = min(num_samples, input.parsed_args["batch-size"])
    x0_log = log.(input.loaded_samples.x0_values)
    z = polee_py[:estimate_transcript_tsne](
        input.loaded_samples.init_feed_dict, num_samples, n,
        input.loaded_samples.variables, x0_log, num_pca_components,
        batch_size)

    if haskey(input.parsed_args, "output-pca-w") && input.parsed_args["output-pca-w"] !== nothing
        write_pca_w(input.parsed_args["output-pca-w"], input, w)
    end

    output_filename = input.output_filename !== nothing ?
        input.output_filename : "transcript-tsne-estimates.csv"
    write_pca_z(output_filename, input, z)
end


function estimate_gene_tsne(input::ModelInput)
    # TODO:
end


function estimate_splicing_tsne(input::ModelInput)
    # TODO:
end


function estimate_transcript_mixture(input::ModelInput)
    num_samples, n = size(input.loaded_samples.x0_values)
    x0_log = log.(input.loaded_samples.x0_values)

    num_pca_components = Int(get(input.parsed_args, "num-pca-components", 8))
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

    num_pca_components = Int(get(input.parsed_args, "num-pca-components", 8))
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


const POLEE_MODELS = Dict(
    "expression"  => estimate_expression,
    "pca"         => estimate_pca,
    "tsne"        => estimate_tsne,
    "mixture"     => estimate_mixture,
    "vae-mixture" => estimate_vae_mixture
)

# Whether each method supports mini-batching.
const BATCH_MODEL = Dict(
    "expression"  => false,
    "pca"         => false,
    "tsne"        => true,
    "mixture"     => false,
    "vae-mixture" => false)
