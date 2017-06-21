

immutable Exon
    first::Int64
    last::Int64
end


function Base.length(e::Exon)
    return e.last - e.first + 1
end


function Base.isless(a::Exon, b::Exon)
    return a.first < b.first
end


function Base.isless(a::Interval, b::Exon)
    return a.first < b.first
end


type TranscriptMetadata
    name::String
    id::Int
    exons::Vector{Exon}
    seq::DNASequence

    function TranscriptMetadata(name, id)
        return new(name, id, Exon[], DNASequence())
    end
end


const Transcript = Interval{TranscriptMetadata}


function exonic_length(t::Transcript)
    el = 0
    for exon in t.metadata.exons
        el += length(exon)
    end
    return el
end


function Base.push!(t::Transcript, e::Exon)
    push!(t.metadata.exons, e)
    t.first = min(t.first, e.first)
    t.last = max(t.last, e.last)
    return e
end


const Transcripts = IntervalCollection{TranscriptMetadata}


type TranscriptsMetadata
    filename::String
    gffsize::Int
    gffhash::Vector{UInt8}

    # kind indexed by transcript_id
    transcript_kind::Dict{String, String}

    # gene_id indexed by transcript_id
    gene_id::Dict{String, String}

    # gene info indexed by gene_id
    gene_name::Dict{String, String}
    gene_biotype::Dict{String, String}
    gene_description::Dict{String, String}
end


function TranscriptsMetadata()
    return TranscriptsMetadata(
        "", 0, UInt8[],
        Dict{String, String}(),
        Dict{String, String}(),
        Dict{String, String}(),
        Dict{String, String}(),
        Dict{String, String}())
end


function Base.haskey(record::GFF3.Record, key::String)
    for (i, k) in enumerate(record.attribute_keys)
        if GFF3.isequaldata(key, record.data, k)
            return true
        end
    end
    return false
end


"""
Get the first value corresponding to the key, or an empty string if the
attribute isn't present.
"""
function getfirst_else_empty(rec::GFF3.Record, key::String)
    return haskey(rec, key) ? GFF3.attributes(rec, key)[1] : ""
end


function Transcripts(filename::String)
    prog_step = 1000
    prog = Progress(filesize(filename), 0.25, "Reading GFF3 file ", 60)

    reader = open(GFF3.Reader, filename)
    entry = eltype(reader)()

    transcript_id_by_name = HATTrie()
    transcript_by_id = Transcript[]
    metadata = TranscriptsMetadata()

    i = 0
    count = 0
    while !isnull(tryread!(reader, entry))
        if (i += 1) % prog_step == 0
            update!(prog, position(reader.state.stream.source))
        end
        count += 1

        typ = GFF3.featuretype(entry)
        entry_id = getfirst_else_empty(entry, "ID")
        if typ == "gene"
            metadata.gene_name[entry_id]        = getfirst_else_empty(entry, "Name")
            metadata.gene_biotype[entry_id]     = getfirst_else_empty(entry, "biotype")
            metadata.gene_description[entry_id] = getfirst_else_empty(entry, "description")
            continue
        end

        parent_name = getfirst_else_empty(entry, "Parent")
        if startswith(parent_name, "gene:")
            metadata.gene_id[entry_id] = parent_name
            metadata.transcript_kind[entry_id] = typ
        end

        if typ != "exon"
            continue
        end

        if parent_name == ""
            error("Exon has no parent")
        end

        # TODO: these other attributes need to be accessed through a function
        id = get!(transcript_id_by_name, parent_name,
                  length(transcript_id_by_name) + 1)
        if id > length(transcript_by_id)
             push!(transcript_by_id,
                 Transcript(StringField(GFF3.seqid(entry)), GFF3.seqstart(entry), GFF3.seqend(entry),
                            GFF3.strand(entry), TranscriptMetadata(parent_name, id)))
        end
        push!(transcript_by_id[id], Exon(GFF3.seqstart(entry), GFF3.seqend(entry)))
    end

    finish!(prog)
    println("Read ", length(transcript_by_id), " transcripts")
    transcripts = IntervalCollection(transcript_by_id, true)

    # reassign transcript indexes to group by position
    # (since it can give the sparse matrix a somewhat better structure)
    for (tid, t) in enumerate(transcripts)
        t.metadata.id = tid
    end

    # make sure all exons arrays are sorted
    for t in transcripts
        sort!(t.metadata.exons)
    end

    metadata.filename = filename
    metadata.gffsize = filesize(filename)
    metadata.gffhash = SHA.sha1(open(filename))

    return transcripts, metadata
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


@inline function Base.next(it::ExonIntronIter, state::Tuple{Int, Bool})
    i, isexon = state
    if isexon
        ex = it.t.metadata.exons[i]
        return ExonIntron(ex.first, ex.last, true), (i, false)
    else
        return ExonIntron(it.t.metadata.exons[i].last+1,
                          it.t.metadata.exons[i+1].first-1, false), (i+1, true)
    end
end


@inline function Base.done(it::ExonIntronIter, state::Tuple{Int, Bool})
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


"""
Serialize a GFF3 file into sqlite3 database.
"""
function write_transcripts(output_filename, transcripts, metadata)
    db = SQLite.DB(output_filename)

    # Gene Table
    # ----------

    gene_nums = Dict{String, Int}()
    for (transcript_id, gene_id) in metadata.gene_id
        get!(gene_nums, gene_id, length(gene_nums) + 1)
    end

    SQLite.execute!(db, "drop table if exists genes")
    SQLite.execute!(db,
        """
        create table genes
        (
            gene_num INT PRIMARY KEY,
            gene_id TEXT,
            gene_name TEXT,
            gene_biotype TEXT,
            gene_description TEXT
        )
        """)

    ins_stmt = SQLite.Stmt(db, "insert into genes values (?1, ?2, ?3, ?4, ?5)")
    SQLite.execute!(db, "begin transaction")
    for (gene_id, gene_num) in gene_nums
        SQLite.bind!(ins_stmt, 1, gene_num)
        SQLite.bind!(ins_stmt, 2, gene_id)
        SQLite.bind!(ins_stmt, 3, get(metadata.gene_name, gene_id, ""))
        SQLite.bind!(ins_stmt, 4, get(metadata.gene_biotype, gene_id, ""))
        SQLite.bind!(ins_stmt, 5, get(metadata.gene_description, gene_id, ""))
        SQLite.execute!(ins_stmt)
    end
    SQLite.execute!(db, "end transaction")

    # Transcript Table
    # ----------------

    SQLite.execute!(db, "drop table if exists transcripts")
    SQLite.execute!(db,
        """
        create table transcripts
        (
            transcript_num INT PRIMARY KEY,
            transcript_id TEXT,
            kind TEXT,
            seqname TEXT,
            strand INT,
            gene_num INT
        )
        """)
    ins_stmt = SQLite.Stmt(db,
        "insert into transcripts values (?1, ?2, ?3, ?4, ?5, ?6)")
    SQLite.execute!(db, "begin transaction")
    for t in transcripts
        SQLite.bind!(ins_stmt, 1, t.metadata.id)
        SQLite.bind!(ins_stmt, 2, String(t.metadata.name))
        SQLite.bind!(ins_stmt, 3, metadata.transcript_kind[t.metadata.name])
        SQLite.bind!(ins_stmt, 4, String(t.seqname))
        SQLite.bind!(ins_stmt, 5,
            t.strand == STRAND_POS ? 1 :
            t.strand == STRAND_NEG ? -1 : 0)
        SQLite.bind!(ins_stmt, 6, gene_nums[metadata.gene_id[t.metadata.name]])
        SQLite.execute!(ins_stmt)
    end
    SQLite.execute!(db, "end transaction")


    # Exon Table
    # ----------

    SQLite.execute!(db, "drop table if exists exons")
    SQLite.execute!(db,
        """
        create table exons
        (
            transcript_num INT,
            first INT,
            last INT
        )
        """)

    ins_stmt = SQLite.Stmt(db, "insert into exons values (?1, ?2, ?3)")
    SQLite.execute!(db, "begin transaction")
    for t in transcripts
        for exon in t.metadata.exons
            SQLite.bind!(ins_stmt, 1, t.metadata.id)
            SQLite.bind!(ins_stmt, 2, exon.first)
            SQLite.bind!(ins_stmt, 3, exon.last)
            SQLite.execute!(ins_stmt)
        end
    end
    SQLite.execute!(db, "end transaction")
end


# TODO: Read from sqlite3


"""
Generate a m-by-n sparse 0/1 matrix F where m is the number of genes, and n
is the number of transcripts, such that givin transcript expression y, Fy
gives gene expression.
"""
function gene_feature_matrix(ts::Transcripts, ts_metadata::TranscriptsMetadata)
    gene_nums = Dict{String, Int}()
    for (transcript_id, gene_id) in ts_metadata.gene_id
        get!(gene_nums, gene_id, length(gene_nums) + 1)
    end

    I = Int[]
    J = Int[]
    for t in ts
        gene_num = gene_nums[ts_metadata.gene_id[t.metadata.name]]
        push!(I, gene_num)
        push!(J, t.metadata.id)
    end

    m = length(gene_nums)
    names = Array{String}(m)
    for (gene_id, gene_num) in gene_nums
        names[gene_num] = gene_id
    end

    return (m, I, J, names)
end
