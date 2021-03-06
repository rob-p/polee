

"""
Multithreaded version of At_mul_B!
"""
function pAt_mul_B!(y::Vector{S}, A::SparseMatrixCSC{T,I}, x::Vector) where {S,T,I}
    colptr = A.colptr
    rowval = A.rowval
    nzval = A.nzval

    Threads.@threads for j in 1:length(y)
        @inbounds begin
            y[j] = zero(T)
            for k_ in colptr[j]:colptr[j+1]-1
                k = Int(k_)
                i = Int(rowval[k])
                y[j] += x[i] * nzval[k]
            end
        end
    end
end


# multiply by 1./x instead of x
function pAt_mulinv_B!(y::Vector{S}, A::SparseMatrixCSC{T,I}, x::Vector) where {S,T,I}
    colptr = A.colptr
    rowval = A.rowval
    nzval = A.nzval

    Threads.@threads for j in 1:length(y)
        @inbounds begin
            y[j] = zero(T)
            for k_ in colptr[j]:colptr[j+1]-1
                k = Int(k_)
                i = Int(rowval[k])
                y[j] += nzval[k] / x[i]
            end
        end
    end
end
