type DArray{T,N,A} <: AbstractArray{T,N}
    dims::NTuple{N,Int}

    chunks::Array{RemoteRef,N}

    # pmap[i]==p ⇒ processor p has piece i
    pmap::Vector{Int}

    # indexes held by piece i
    indexes::Array{NTuple{N,Range1{Int}},N}
    # cuts[d][i] = first index of chunk i in dimension d
    cuts::Vector{Vector{Int}}

    function DArray(dims, chunks, pmap, indexes, cuts)
        # check invariants
        assert(size(chunks) == size(indexes))
        assert(length(chunks) == length(pmap))
        assert(dims == map(last,last(indexes)))
        new(dims, chunks, pmap, indexes, cuts)
    end
end

typealias SubDArray{T,N,D<:DArray} SubArray{T,N,D}
typealias SubOrDArray{T,N}         Union(DArray{T,N}, SubDArray{T,N})

## core constructors ##

# dist == size(chunks)
function DArray(init, dims, procs, dist)
    np = prod(dist)
    procs = procs[1:np]
    idxs, cuts = chunk_idxs([dims...], dist)
    chunks = Array(RemoteRef, dist...)
    for i = 1:np
        chunks[i] = remote_call(procs[i], init, idxs[i])
    end
    p = max(1, localpiece(procs))
    A = remote_call_fetch(procs[p], r->typeof(fetch(r)), chunks[p])
    DArray{eltype(A),length(dims),A}(dims, chunks, procs, idxs, cuts)
end

function DArray(init, dims, procs)
    if isempty(procs)
        error("DArray: no processors!")
    end
    DArray(init, dims, procs, defaultdist(dims,procs))
end
DArray(init, dims) = DArray(init, dims, [1:min(nprocs(),max(dims))])

size(d::DArray) = d.dims
procs(d::DArray) = d.pmap

chunktype{T,N,A}(d::DArray{T,N,A}) = A

## chunk index utilities ##

# decide how to divide each dimension
# returns size of chunks array
function defaultdist(dims, procs)
    dims = [dims...]
    chunks = ones(Int, length(dims))
    np = length(procs)
    f = sortr(keys(factor(np)))
    k = 1
    while np > 1
        # repeatedly allocate largest factor to largest dim
        if np%f[k] != 0
            k += 1
            if k > length(f)
                break
            end
        end
        fac = f[k]
        (d, dno) = findmax(dims)
        # resolve ties to highest dim
        dno = last(find(dims .== d))
        if dims[dno] >= fac
            dims[dno] = div(dims[dno], fac)
            chunks[dno] *= fac
        end
        np = div(np,fac)
    end
    chunks
end

# get array of start indexes for dividing sz into nc chunks
function defaultdist(sz::Int, nc::Int)
    if sz >= nc
        linspace(1, sz+1, nc+1)
    else
        [[1:(sz+1)], zeros(Int, nc-sz)]
    end
end

# compute indexes array for dividing dims into chunks
function chunk_idxs(dims, chunks)
    cuts = map(defaultdist, dims, chunks)
    n = length(dims)
    idxs = Array(NTuple{n,Range1{Int}},chunks...)
    cartesian_map(tuple(chunks...)) do cidx...
        idxs[cidx...] = ntuple(n, i->(cuts[i][cidx[i]]:cuts[i][cidx[i]+1]-1))
    end
    idxs, cuts
end

function localpiece(pmap::Vector{Int})
    mi = myid()
    for i = 1:length(pmap)
        if pmap[i] == mi
            return i
        end
    end
    return 0
end

localpiece(d::DArray) = localpiece(d.pmap)

localize{T,N,A}(d::DArray{T,N,A}) = fetch(d.chunks[localpiece(d)])::A
myindexes(d::DArray) = d.indexes[localpiece(d)]

# find which piece holds index (I...)
function locate(d::DArray, I::Int...)
    ntuple(ndims(d), i->search_sorted_last(d.cuts[i], I[i]))
end

chunk{T,N,A}(d::DArray{T,N,A}, i...) = fetch(d.chunks[i...])::A

## convenience constructors ##

drand(args...)  = DArray(I->rand(map(length,I)), args...)
drand(d::Int...) = drand(d)
drandn(args...) = DArray(I->randn(map(length,I)), args...)
drandn(d::Int...) = drandn(d)

## conversions ##

function distribute(a::Array)
    owner = myid()
    rr = RemoteRef()
    put(rr, a)
    DArray(size(a)) do I
        remote_call_fetch(owner, ()->fetch(rr)[I...])
    end
end

convert{T,N}(::Type{Array}, d::SubOrDArray{T,N}) = convert(Array{T,N}, d)

function convert{S,T,N}(::Type{Array{S,N}}, d::DArray{T,N})
    a = Array(S, size(d))
    @sync begin
        for i = 1:length(d.chunks)
            @spawnlocal a[d.indexes[i]...] = chunk(d, i)
        end
    end
    a
end

function convert{S,T,N}(::Type{Array{S,N}}, s::SubDArray{T,N})
    I = s.indexes
    d = s.parent
    if isa(I,(Range1{Int}...)) && subtype(S,T) && subtype(T,S)
        l = locate(d, map(first, I)...)
        if isequal(d.indexes[l...], I)
            # SubDArray corresponds to a chunk
            return chunk(d, l...)
        end
    end
    a = Array(S, size(s))
    a[[1:size(a,i) for i=1:N]...] = s
    a
end

## indexing ##

function ref(r::RemoteRef, args...)
    if r.where==myid()
        ref(fetch(r), args...)
    else
        remote_call_fetch(r.where, ref, r, args...)
    end
end

ref(d::DArray, i::Int) = ref(d, ind2sub(size(d), i))
ref(d::DArray, i::Int...) = ref(d, sub2ind(size(d), i...))

function ref{T}(d::DArray{T}, I::(Int...))
    chidx = locate(d, I...)
    chunk = d.chunks[chidx...]
    idxs = d.indexes[chidx...]
    localidx = ntuple(ndims(d), i->(I[i]-first(idxs[i])+1))
    chunk[localidx...]::T
end

ref(d::DArray) = d[1]
ref(d::DArray, I::Union(Int,Range1{Int})...) = sub(d,I)

copy(d::SubOrDArray) = d

# local copies are obtained by convert(Array, ) or assigning from
# a SubDArray to a local Array.

function assign(a::Array, d::DArray, I::Range1{Int}...)
    n = length(I)
    @sync begin
        for i = 1:length(d.chunks)
            K = d.indexes[i]
            @spawnlocal a[[I[j][K[j]] for j=1:n]...] = chunk(d, i)
        end
    end
    a
end

function assign(a::Array, s::SubDArray, I::Range1{Int}...)
    n = length(I)
    d = s.parent
    J = s.indexes
    offs = [isa(J[i],Int) ? J[i]-1 : first(J[i])-1 for i=1:n]
    @sync begin
        for i = 1:length(d.chunks)
            K_c = d.indexes[i]
            K = [ intersect(J[j],K_c[j]) for j=1:n ]
            if !anyp(isempty, K)
                idxs = [ I[j][K[j]-offs[j]] for j=1:n ]
                if isequal(K, K_c)
                    # whole chunk
                    @spawnlocal a[idxs...] = chunk(d, i)
                else
                    # partial chunk
                    ch = d.chunks[i]
                    @spawnlocal a[idxs...] = remote_call_fetch(ch.where, ()->sub(fetch(ch), [K[j]-first(K_c[j])+1 for j=1:n]...))
                end
            end
        end
    end
    a
end

# to disambiguate
assign(a::Array{Any}, d::SubOrDArray, i::Int) = assign(a, d, i:i)

assign(a::Array, d::SubOrDArray, I::Union(Int,Range1{Int})...) =
    assign(a, d, [isa(i,Int) ? (i:i) : i for i in I ]...)