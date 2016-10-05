

immutable Exon
    first::Int64
    last::Int64
end


function Base.isless(a::Exon, b::Exon)
    return a.first < b.first
end


type TranscriptMetadata
    name::StringField
    id::Int
    exons::Vector{Exon}
    seq::DNASequence

    function TranscriptMetadata(name, id)
        return new(name, id, Exon[], DNASequence())
    end
end


typealias Transcript Interval{TranscriptMetadata}


function Base.push!(t::Transcript, e::Exon)
    push!(t.metadata.exons, e)
    t.first = min(t.first, e.first)
    t.last = max(t.last, e.last)
    return e
end


type Transcripts
    transcripts::IntervalCollection{TranscriptMetadata}
    transcripts_by_name::Dict{StringField, Transcript}

end


function Transcripts(filename::String)
    prog = Progress(filesize(filename), 0.25, "Reading GFF3 file ", 60)
    reader = open(GFF3Reader, filename)
    entry = eltype(reader)()
    transcripts_by_name = Dict{StringField, Transcript}()

    i = 0
    while !isnull(tryread!(reader, entry))
        if (i += 1) % 1000 == 0
            update!(prog, position(reader.state.stream.source))
        end
        if entry.metadata.kind == "exon"
            if !haskey(entry.metadata.attributes, "Parent")
                error("Exon has no parent")
            end

            parent_name = entry.metadata.attributes["Parent"]
            if !haskey(transcripts_by_name, parent_name)
                parent_name = copy(parent_name)
                id = length(transcripts_by_name) + 1
                transcripts_by_name[parent_name] =
                    Transcript(copy(entry.seqname), entry.first, entry.last,
                                   entry.strand, TranscriptMetadata(parent_name, id))
            end
            push!(transcripts_by_name[parent_name], Exon(entry.first, entry.last))
        end
    end

    finish!(prog)
    println("Read ", length(transcripts_by_name), " transcripts")
    is = collect(values(transcripts_by_name))
    transcripts = IntervalCollection(is, true)

    # make sure all exons arrays are sorted
    for t in transcripts
        sort!(t.metadata.exons)
    end

    return Transcripts(transcripts, transcripts_by_name)
end


immutable ExonIntron
    first::Int
    last::Int
    isexon::Bool
end


function Base.length(e::ExonIntron)
    return e.last - e.first + 1
end


"""
Iterate over exons and introns in a transcript in order Interval{Bool} where
metadata flag is true for exons.
"""
immutable ExonIntronIter
    t::Transcript
end


function Base.start(it::ExonIntronIter)
    return 1, true
end


function Base.next(it::ExonIntronIter, state::Tuple{Int, Bool})
    i, isexon = state
    if isexon
        ex = it.t.metadata.exons[i]
        return ExonIntron(ex.first, ex.last, true), (i, false)
    else
        return ExonIntron(it.t.metadata.exons[i].last+1,
                          it.t.metadata.exons[i+1].first-1, false), (i+1, true)
    end
end


function Base.done(it::ExonIntronIter, state::Tuple{Int, Bool})
    return state[1] == length(it.t.metadata.exons) && !state[2]
end


function genomic_to_transcriptomic(t::Transcript, position::Integer)
    exons = t.metadata.exons
    i = searchsortedlast(exons, Exon(position, position))
    if i == 0 || exons[i].last < position
        return 0
    else
        tpos = 1
        for j in 1:i-1
            tpos += exons[j].last - exons[j].first + 1
        end
        return tpos + position - t.metadata.exons[i].first
    end
end

