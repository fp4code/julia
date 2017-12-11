# This file is a part of Julia. License is MIT: https://julialang.org/license

const Bits = Vector{UInt64}
const Chk0 = zero(UInt64)
const NoOffset = -one(Int) << 60
# + NoOffset must be big enough to stay < 0 when add with any offset.
#   An offset is in the range -2^57:2^57
# + when the offset is NoOffset, the bits field *must* be empty
# + NoOffset could be made to be > 0, but a negative one allows
#   a small optimization in the in(x, ::BitSet)

mutable struct BitSet <: AbstractSet{Int}
    bits::Vector{UInt64}
    # 1st stored Int equals 64*offset
    offset::Int

    BitSet() = new(sizehint!(zeros(UInt64, 0), 4), NoOffset)
end

"""
    BitSet([itr])

Construct a sorted set of `Int`s generated by the given iterable object, or an
empty set. Implemented as a bit string, and therefore designed for dense integer sets.
If the set will be sparse (for example holding a few
very large integers), use [`Set`](@ref) instead.
"""
BitSet(itr) = union!(BitSet(), itr)

@inline intoffset(s::BitSet) = s.offset << 6

eltype(::Type{BitSet}) = Int
similar(s::BitSet) = BitSet()
copy(s1::BitSet) = copy!(BitSet(), s1)
function copy!(dest::BitSet, src::BitSet)
    resize!(dest.bits, length(src.bits))
    copy!(dest.bits, src.bits)
    dest.offset = src.offset
    dest
end

eltype(s::BitSet) = Int

sizehint!(s::BitSet, n::Integer) = sizehint!(s.bits, n)

# given an integer i, return the chunk which stores it
chk_indice(i::Int) = i >> 6
# return the bit offset of i within chk_indice(i)
chk_offset(i::Int) = i & 63

function _bits_getindex(b::Bits, n::Int, offset::Int)
    ci = chk_indice(n) - offset + 1
    ci > length(b) && return false
    @inbounds r = (b[ci] & (one(UInt64) << chk_offset(n))) != 0
    r
end

function _bits_findnext(b::Bits, start::Int)
    # start is 0-based
    # @assert start >= 0
    chk_indice(start) + 1 > length(b) && return -1
    unsafe_bitfindnext(b, start+1) - 1
end

function _bits_findprev(b::Bits, start::Int)
    # start is 0-based
    # @assert start <= 64 * length(b) - 1
    start >= 0 || return -1
    unsafe_bitfindprev(b, start+1) - 1
end

# An internal function for setting the inclusion bit for a given integer
@inline function _setint!(s::BitSet, idx::Int, b::Bool)
    cidx = chk_indice(idx)
    len = length(s.bits)
    diff = cidx - s.offset
    if diff >= len
        b || return s # setting a bit to zero outside the set's bits is a no-op

        # we put the following test within one of the two branches,
        # with the NoOffset trick, to avoid having to perform it at
        # each and every call to _setint!
        if s.offset == NoOffset # initialize the offset
            # we assume isempty(s.bits)
            s.offset = cidx
            diff = 0
        end
        _growend0!(s.bits, diff - len + 1)
    elseif diff < 0
        b || return s
        _growbeg0!(s.bits, -diff)
        s.offset += diff
        diff = 0
    end
    _unsafe_bitsetindex!(s.bits, b, diff+1, chk_offset(idx))
    s
end


# An internal function to resize a Bits object and ensure the newly allocated
# elements are zeroed (will become unnecessary if this behavior changes)
@inline function _growend0!(b::Bits, nchunks::Int)
    len = length(b)
    _growend!(b, nchunks)
    @inbounds b[len+1:end] = Chk0 # resize! gives dirty memory
end

@inline function _growbeg0!(b::Bits, nchunks::Int)
    _growbeg!(b, nchunks)
    @inbounds b[1:nchunks] = Chk0
end

function _matched_map!(f, s1::BitSet, s2::BitSet)
    left_false_is_false = f(false, false) == f(false, true) == false
    right_false_is_false = f(false, false) == f(true, false) == false

    # we must first handle the NoOffset case; we could test for
    # isempty(s1) but it can be costly, so the user has to call
    # empty!(s1) herself before-hand to re-initialize to NoOffset
    if s1.offset == NoOffset
        return left_false_is_false ? s1 : copy!(s1, s2)
    elseif s2.offset == NoOffset
        return right_false_is_false ? empty!(s1) : s1
    end
    o1 = _matched_map!(f, s1.bits, s1.offset, s2.bits, s2.offset,
                       left_false_is_false, right_false_is_false)
    s1.offset = o1
    s1
end

# An internal function that takes a pure function `f` and maps across two BitArrays
# allowing the lengths and offsets to be different and altering b1 with the result
# WARNING: the assumptions written in the else clauses must hold
function _matched_map!(f, a1::Bits, b1::Int, a2::Bits, b2::Int,
                       left_false_is_false::Bool, right_false_is_false::Bool)
    l1, l2 = length(a1), length(a2)
    bdiff = b2 - b1
    e1, e2 = l1+b1, l2+b2
    ediff = e2 - e1

    # map! over the common indices
    @inbounds for i = max(1, 1+bdiff):min(l1, l2+bdiff)
        a1[i] = f(a1[i], a2[i-bdiff])
    end

    if ediff > 0
        if left_false_is_false
            # We don't need to worry about the trailing bits — they're all false
        else # @assert f(false, x) == x
            _growend!(a1, ediff)
            # if a1 and a2 are not overlapping, we infer implied "false" values from a2
            @inbounds for outer l1 = l1+1:bdiff
                a1[l1] = Chk0
            end
            # update ediff in case l1 was updated
            ediff = e2 - l1 - b1
            # copy actual chunks from a2
            unsafe_copy!(a1, l1+1, a2, l2+1-ediff, ediff)
        end
    elseif ediff < 0
        if right_false_is_false
            # We don't need to worry about the trailing bits — they're all false
            _deleteend!(a1, max(l1, -ediff))
        else # @assert f(x, false) == x
            # We don't need to worry about the trailing bits — they already have the
            # correct value
        end
    end

    if bdiff < 0
        if left_false_is_false
            # We don't need to worry about the leading bits — they're all false
        else # @assert f(false, x) == x
            _growbeg!(a1, -bdiff)
            # if a1 and a2 are not overlapping, we infer implied "false" values from a2
            @inbounds for i = l2+1:bdiff
                a1[i] = Chk0
            end
            b1 += bdiff # updated return value

            # copy actual chunks from a2
            unsafe_copy!(a1, 1, a2, 1, min(-bdiff, l2))
        end
    elseif bdiff > 0
        if right_false_is_false
            # We don't need to worry about the trailing bits — they're all false
            _deletebeg!(a1, bdiff)
        else # @assert f(x, false) == x
            # We don't need to worry about the trailing bits — they already have the
            # correct value
        end
    end
    b1 # the new offset
end


@noinline _throw_bitset_bounds_err() =
    throw(ArgumentError("elements of BitSet must be between typemin(Int) and typemax(Int)"))

@inline _is_convertible_Int(n) = typemin(Int) <= n <= typemax(Int)

@inline _check_bitset_bounds(n) =
    _is_convertible_Int(n) ? Int(n) : _throw_bitset_bounds_err()

@inline _check_bitset_bounds(n::Int) = n

@noinline _throw_keyerror(n) = throw(KeyError(n))

@inline push!(s::BitSet, n::Integer) = _setint!(s, _check_bitset_bounds(n), true)

push!(s::BitSet, ns::Integer...) = (for n in ns; push!(s, n); end; s)

@inline pop!(s::BitSet) = pop!(s, last(s))

@inline function pop!(s::BitSet, n::Integer)
    n in s ? (delete!(s, n); n) : _throw_keyerror(n)
end

@inline function pop!(s::BitSet, n::Integer, default)
    n in s ? (delete!(s, n); n) : default
end

@inline delete!(s::BitSet, n::Int) = _setint!(s, n, false)
@inline delete!(s::BitSet, n::Integer) = _is_convertible_Int(n) ? delete!(s, Int(n)) : s

shift!(s::BitSet) = pop!(s, first(s))

function empty!(s::BitSet)
    empty!(s.bits)
    s.offset = NoOffset
    s
end

isempty(s::BitSet) = all(equalto(Chk0), s.bits)

# Mathematical set functions: union!, intersect!, setdiff!, symdiff!

union(s::BitSet) = copy(s)
union(s1::BitSet, s2::BitSet) = union!(copy(s1), s2)
union(s1::BitSet, ss::BitSet...) = union(s1, union(ss...))
union(s::BitSet, ns) = union!(copy(s), ns)
union!(s::BitSet, ns) = (for n in ns; push!(s, n); end; s)
union!(s1::BitSet, s2::BitSet) = _matched_map!(|, s1, s2)

intersect(s1::BitSet) = copy(s1)
intersect(s1::BitSet, ss::BitSet...) = intersect(s1, intersect(ss...))
function intersect(s1::BitSet, ns)
    s = BitSet()
    for n in ns
        n in s1 && push!(s, n)
    end
    s
end
intersect(s1::BitSet, s2::BitSet) =
    length(s1.bits) < length(s2.bits) ? intersect!(copy(s1), s2) : intersect!(copy(s2), s1)
"""
    intersect!(s1::BitSet, s2::BitSet)

Intersects sets `s1` and `s2` and overwrites the set `s1` with the result. If needed, `s1`
will be expanded to the size of `s2`.
"""
intersect!(s1::BitSet, s2::BitSet) = _matched_map!(&, s1, s2)

setdiff(s::BitSet, ns) = setdiff!(copy(s), ns)
setdiff!(s::BitSet, ns) = (for n in ns; delete!(s, n); end; s)
setdiff!(s1::BitSet, s2::BitSet) = _matched_map!((p, q) -> p & ~q, s1, s2)

symdiff(s::BitSet, ns) = symdiff!(copy(s), ns)
"""
    symdiff!(s, itr)

For each element in `itr`, destructively toggle its inclusion in set `s`.
"""
symdiff!(s::BitSet, ns) = (for n in ns; int_symdiff!(s, n); end; s)
"""
    symdiff!(s, n)

The set `s` is destructively modified to toggle the inclusion of integer `n`.
"""
symdiff!(s::BitSet, n::Integer) = int_symdiff!(s, n)

function int_symdiff!(s::BitSet, n::Integer)
    n0 = _check_bitset_bounds(n)
    val = !(n0 in s)
    _setint!(s, n0, val)
    s
end

symdiff!(s1::BitSet, s2::BitSet) = _matched_map!(xor, s1, s2)

@inline in(n::Int, s::BitSet) = _bits_getindex(s.bits, n, s.offset)
@inline in(n::Integer, s::BitSet) = _is_convertible_Int(n) ? in(Int(n), s) : false

# Use the next-set index as the state to prevent looking it up again in done
start(s::BitSet) = _bits_findnext(s.bits, 0)

function next(s::BitSet, i::Int)
    nextidx = _bits_findnext(s.bits, i+1)
    (i+intoffset(s), nextidx)
end

done(s::BitSet, i) = i == -1

@noinline _throw_bitset_notempty_error() =
    throw(ArgumentError("collection must be non-empty"))

function first(s::BitSet)
    idx = _bits_findnext(s.bits, 0)
    idx == -1 ? _throw_bitset_notempty_error() : idx + intoffset(s)
end

function last(s::BitSet)
    idx = _bits_findprev(s.bits, (length(s.bits) << 6) - 1)
    idx == -1 ? _throw_bitset_notempty_error() : idx + intoffset(s)
end

length(s::BitSet) = bitcount(s.bits) # = mapreduce(count_ones, +, 0, s.bits)

function show(io::IO, s::BitSet)
    print(io, "BitSet([")
    first = true
    for n in s
        !first && print(io, ", ")
        print(io, n)
        first = false
    end
    print(io, "])")
end

function _check0(a::Vector{UInt64}, b::Int, e::Int)
    @inbounds for i in b:e
        a[i] == Chk0 || return false
    end
    true
end

function ==(s1::BitSet, s2::BitSet)
    # Swap so s1 has always the smallest offset
    if s1.offset > s2.offset
        s1, s2 = s2, s1
    end
    a1 = s1.bits
    a2 = s2.bits
    b1, b2 = s1.offset, s2.offset
    l1, l2 = length(a1), length(a2)
    e1 = l1+b1
    overlap0 = max(0, e1 - b2)
    included = overlap0 >= l2  # whether a2's indices are included in a1's
    overlap  = included ? l2 : overlap0

    # compare overlap values
    if overlap > 0
        _memcmp(pointer(a1, b2-b1+1), pointer(a2), overlap<<3) == 0 || return false
    end

    # Ensure remaining chunks are zero
    _check0(a1, 1, l1-overlap0) || return false
    if included
        _check0(a1, b2-b1+l2+1, l1)
    else
        _check0(a2, 1+overlap, l2) || return false
    end
    return true
end

issubset(a::BitSet, b::BitSet) = isequal(a, intersect(a,b))
<(a::BitSet, b::BitSet) = (a<=b) && !isequal(a,b)
<=(a::BitSet, b::BitSet) = issubset(a, b)

const hashis_seed = UInt === UInt64 ? 0x88989f1fc7dea67d : 0xc7dea67d
function hash(s::BitSet, h::UInt)
    h ⊻= hashis_seed
    bc = s.bits
    i = 1
    j = length(bc)

    while j > 0 && bc[j] == Chk0
        # Skip trailing empty bytes to prevent extra space from changing the hash
        j -= 1
    end
    while i <= j && bc[i] == Chk0
        # Skip leading empty bytes to prevent extra space from changing the hash
        i += 1
    end
    i > j && return h # empty
    h = hash(i+s.offset, h) # normalized offset
    while j >= i
        h = hash(bc[j], h)
        j -= 1
    end
    h
end

minimum(s::BitSet) = first(s)
maximum(s::BitSet) = last(s)
extrema(s::BitSet) = (first(s), last(s))
issorted(s::BitSet) = true

nothing
