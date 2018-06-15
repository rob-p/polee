
"""
Model of conditional fragment probabilities. Should implement:

condfragprob(fm, t::Transcript, rs::Reads, alnpr::AlignmentPair, effective_length::Float32)
effective_length(fm, t::Transcript)
"""
abstract type FragModel; end


function fragment_length_prob(fm::FragModel, fraglen)
    if fm.use_fallback_fraglen_dist
        return Float32(pdf(fm.fallback_fraglen_dist, fraglen))
    else
        if fraglen <= MAX_FRAG_LEN
            return fm.fraglen_pmf[fraglen]
        else
            return 0.0f0
        end
    end
end


"""
A simple fragment model without any bias modeling.
"""
struct SimplisticFragModel <: FragModel
    fraglen_pmf::Vector{Float32}
    fraglen_cdf::Vector{Float32}
    fallback_fraglen_dist::Normal{Float32}
    use_fallback_fraglen_dist::Bool
    strand_specificity::Float32
end


function SimplisticFragModel(rs::Reads, ts::Transcripts)
    examples = rs.alignment_pairs

    # alignment pair fragment lengths
    alnpr_fraglen = ObjectIdDict()

    strand_match_count = 0
    strand_mismatch_count = 0

    for (t, alnpr) in eachoverlap(ts, examples)
        if alnpr.strand == t.strand
            strand_match_count += 1
        elseif alnpr.strand != STRAND_BOTH
            strand_mismatch_count += 1
        end

        # collect fragment lengths
        fraglen = fragmentlength(t, rs, alnpr)

        if !isnull(fraglen) && get(fraglen) > 0
            fl = get(fraglen)
            if haskey(alnpr_fraglen, alnpr)
                alnpr_fraglen[alnpr] = min(alnpr_fraglen[alnpr], fl)
            else
                alnpr_fraglen[alnpr] = fl
            end
        end
    end

    strand_specificity = strand_match_count /
        (strand_match_count + strand_mismatch_count)
    negentropy = strand_specificity * log2(strand_specificity) +
        (1.0 - strand_specificity) * log2(1.0 - strand_specificity)
    println("Strand specificity: ", round(100.0 * (1 + negentropy), 1), "%")

    # compute fragment length frequencies
    fraglen_pmf = fill(1.0, MAX_FRAG_LEN) # init with pseudocount
    for fl in values(alnpr_fraglen)
        if fl <= MAX_FRAG_LEN
            fraglen_pmf[fl] += 1
        end
    end
    fraglen_pmf_count = sum(fraglen_pmf) - MAX_FRAG_LEN
    fraglen_pmf ./= sum(fraglen_pmf)

    # out = open("fraglen.csv", "w")
    # println(out, "fraglen,freq")
    # for (fl, freq) in enumerate(fraglen_pmf)
    #     println(out, fl, ",", freq)
    # end

    fraglen_cdf = copy(fraglen_pmf)
    for i in 2:length(fraglen_cdf)
        fraglen_cdf[i] += fraglen_cdf[i-1]
    end

    use_fallback_fraglen_dist = fraglen_pmf_count < MIN_FRAG_LEN_COUNT
    return SimplisticFragModel(
        fraglen_pmf, fraglen_cdf, Normal(200, 100),
        use_fallback_fraglen_dist, strand_specificity)
end

function compute_transcript_bias!(fm::SimplisticFragModel, ts::Transcripts)
end


function condfragprob(fm::SimplisticFragModel, t::Transcript, rs::Reads,
                      alnpr::AlignmentPair, effective_length::Float32)
    fraglen_ = fragmentlength(t, rs, alnpr)
    if isnull(fraglen_)
        return 0.0f0
    end
    fraglen = get(fraglen_)

    # single-end read
    if fraglen <= 0
        aln = alnpr.metadata.mate1_idx > 0 ?
                    rs.alignments[alnpr.metadata.mate1_idx] : rs.alignments[alnpr.metadata.mate2_idx]
        if aln.flag == SAM.FLAG_REVERSE != 0
            max_frag_len = aln.rightpos - t.first + 1
        else
            max_frag_len = t.last - aln.leftpos + 1
        end

        fraglen = min(max_frag_len, round(Int, mean(fm.fallback_fraglen_dist)))
    end

    fraglenpr = fragment_length_prob(fm, fraglen)
    fragpr = fraglenpr / effective_length

    return fragpr
end


function effective_length(fm::SimplisticFragModel, t::Transcript)
    tlen = exonic_length(t)
    el = 0.0f0
    for l in 1:min(tlen, MAX_FRAG_LEN)
        el += fm.fraglen_pmf[l] * (tlen - l + 1)
    end
    return Float32(max(el, MIN_EFFECTIVE_LENGTH))
end



mutable struct BiasedFragModel <: FragModel
    fraglen_pmf::Vector{Float32}
    fraglen_cdf::Vector{Float32}
    fallback_fraglen_dist::Normal{Float32}
    use_fallback_fraglen_dist::Bool
    strand_specificity::Float32
    bias_model::BiasModel
end



function BiasedFragModel(rs::Reads, ts::Transcripts, read_assignments::Dict{Int, Int})

    ts_by_id = collect(Transcript, ts)

    # strand-preference and fragment length distribution are estimated seperately
    # from other bias effects to simplify things. This way we can just randomly
    # shift reads without resizing fragments or changing strand.

    bias_foreground_examples = BiasTrainingExample[]
    bias_background_examples = BiasTrainingExample[]

    strand_match_count = 0
    strand_mismatch_count = 0
    fraglens = Int[]

    for alnpr in rs.alignment_pairs
        read_id = rs.alignments[alnpr.metadata.mate1_idx].id
        transcript_id = get(read_assignments, read_id, 0)
        if transcript_id == 0
            continue
        end
        t = ts_by_id[transcript_id]
        tseq = t.metadata.seq

        fragint = genomic_to_transcriptomic(t, rs, alnpr)
        fl = length(fragint)
        tpos = fragint.start

        if alnpr.strand == t.strand
            strand_match_count += 1
        elseif alnpr.strand != STRAND_BOTH
            strand_mismatch_count += 1
        end

        if fl <= 0 || tpos < 1 || tpos + fl - 1 > length(tseq)
            continue
        end

        # fraqseq = extract_padded_seq(
        #     tseq, tpos - BIAS_SEQ_FRAG_PAD_LEFT, tpos + fl - 1 + BIAS_SEQ_FRAG_PAD_RIGHT)
        push!(bias_foreground_examples, BiasTrainingExample(tseq, tpos, fl))

        # perturb fragment position and record context as a background sample
        tpos = rand(1:length(tseq)-fl+1)
        # fraqseq = extract_padded_seq(
        #     tseq, tpos - BIAS_SEQ_FRAG_PAD_LEFT, tpos + fl - 1 + BIAS_SEQ_FRAG_PAD_RIGHT)
        push!(bias_background_examples, BiasTrainingExample(tseq, tpos, fl))
    end

    @show length(read_assignments)
    @show length(rs.alignment_pairs)
    @show length(fraglens)
    @show length(bias_foreground_examples)

    strand_specificity = strand_match_count /
        (strand_match_count + strand_mismatch_count)
    negentropy = strand_specificity * log2(strand_specificity) +
        (1.0 - strand_specificity) * log2(1.0 - strand_specificity)
    println("Strand specificity: ", round(100.0 * (1 + negentropy), 1), "%")

    # compute fragment length frequencies
    fraglen_pmf = fill(1.0, MAX_FRAG_LEN) # init with pseudocount
    for fl in fraglens
        if fl <= MAX_FRAG_LEN
            fraglen_pmf[fl] += 1
        end
    end
    fraglen_pmf ./= sum(fraglen_pmf)

    # out = open("fraglen.csv", "w")
    # println(out, "fraglen,freq")
    # for (fl, freq) in enumerate(fraglen_pmf)
    #     println(out, fl, ",", freq)
    # end

    fraglen_cdf = copy(fraglen_pmf)
    for i in 2:length(fraglen_cdf)
        fraglen_cdf[i] += fraglen_cdf[i-1]
    end

    use_fallback_fraglen_dist = length(fraglens) < MIN_FRAG_LEN_COUNT

    p = shuffle(1:length(bias_foreground_examples))
    bias_foreground_examples = bias_foreground_examples[p]
    bias_background_examples = bias_background_examples[p]
    n_training = floor(Int, 0.8 * length(bias_foreground_examples))

    bias_foreground_training_examples = bias_foreground_examples[1:n_training]
    bias_background_training_examples = bias_background_examples[1:n_training]
    bias_foreground_testing_examples = bias_foreground_examples[n_training+1:end]
    bias_background_testing_examples = bias_background_examples[n_training+1:end]

    bias_model = BiasModel(
        bias_foreground_training_examples,
        bias_background_training_examples,
        bias_foreground_testing_examples,
        bias_background_testing_examples)

    #=
    open("bias-foreground.csv", "w") do output
        for example in bias_foreground_examples
            println(
                output, example.left_seq,
                ',', example.right_seq,
                ',', example.frag_gc,
                ',', example.tpdist,
                ',', example.fpdist,
                ',', example.tlen,
                ',', example.fl,
                ',', join(example.a_freqs, ','),
                ',', join(example.c_freqs, ','),
                ',', join(example.g_freqs, ','),
                ',', join(example.t_freqs, ','))
        end
    end

    open("bias-background.csv", "w") do output
        for example in bias_background_examples
            println(
                output, example.left_seq,
                ',', example.right_seq,
                ',', example.frag_gc,
                ',', example.tpdist,
                ',', example.fpdist,
                ',', example.tlen,
                ',', example.fl,
                ',', join(example.a_freqs, ','),
                ',', join(example.c_freqs, ','),
                ',', join(example.g_freqs, ','),
                ',', join(example.t_freqs, ','))
        end
    end
    =#

    return BiasedFragModel(
        fraglen_pmf, fraglen_cdf, Normal(200, 100),
        use_fallback_fraglen_dist, strand_specificity,
        bias_model)
end


function compute_transcript_bias!(fm::BiasedFragModel, ts::Transcripts)
    for t in ts
        compute_transcript_bias!(fm.bias_model, t)
    end
end


function effective_length(fm::BiasedFragModel, t::Transcript)
    tseq = t.metadata.seq
    tlen = length(tseq)
    efflen = 0.0f0

    left_bias = t.metadata.left_bias
    right_bias = t.metadata.right_bias

    for fraglen in 1:tlen
        fraglenpr = fragment_length_prob(fm, fraglen)
        if fraglenpr < BIAS_MIN_FRAGLEN_PR
            continue
        end

        frag_gc_count = 0
        for pos in 1:fraglen
            nt = tseq[pos]
            frag_gc_count += isGC(nt)
        end

        c = 0f0
        for pos in 1:tlen-fraglen+1
            if pos > 1
                frag_gc_count -= isGC(tseq[pos-1])
                frag_gc_count += isGC(tseq[pos+fraglen-1])
            end

            c += exp(
                left_bias[pos] +
                right_bias[pos+fraglen-1] +
                evaluate(fm.bias_model.gc_model, frag_gc_count/fraglen))
        end
        efflen += c * fraglenpr
    end

    return efflen
end


function condfragprob(fm::BiasedFragModel, t::Transcript, rs::Reads,
                      alnpr::AlignmentPair, effective_length::Float32)
    tseq = t.metadata.seq
    tlen = length(tseq)
    fragint = genomic_to_transcriptomic(t, rs, alnpr)
    fraglenpr = fragment_length_prob(fm, length(fragint))
    frag_gc = gc_content(tseq[fragint])

    fragbias = exp(
        t.metadata.left_bias[fragint.start],
        t.metadata.right_bias[fragint.stop],
        # evaluate(
        #     fm.bias_model.left_seqbias,
        #     extract_padded_seq(
        #         tseq,
        #         fragint.start - BIAS_SEQ_OUTER_CTX,
        #         fragint.start + BIAS_SEQ_INNER_CTX - 1)) +
        # evaluate(
        #     fm.bias_model.right_seqbias,
        #     extract_padded_seq(
        #         tseq,
        #         fragint.stop - BIAS_SEQ_OUTER_CTX,
        #         fragint.stop + BIAS_SEQ_OUTER_CTX - 1)) +
        # evaluate(fm.bias_model.pos_model, tlen, fragint.start/tlen) +
        evaluate(fm.bias_model.gc_model, frag_gc))

    fragpr = fraglenpr * fragbias / effective_length
    return fragpr
end
