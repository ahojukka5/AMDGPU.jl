Base.to_index(::ROCArray, I::AbstractArray{Bool}) = findall(I)

# TODO Julia 1.11 specifics

function Base.findall(bools::AnyROCArray{Bool})
    I = keytype(bools)
    indices = cumsum(reshape(bools, prod(size(bools))))

    n = @allowscalar indices[end]
    ys = ROCArray{I}(undef, n)

    if n > 0
        function _ker!(ys, bools, indices)
            i = workitemIdx().x + (workgroupIdx().x - Int32(1)) * workgroupDim().x

            @inbounds if i ≤ length(bools) && bools[i]
                ii = CartesianIndices(bools)[i]
                b = indices[i] # new position
                ys[b] = ii
            end
            return
        end

        kernel = @roc launch=false _ker!(ys, bools, indices)
        config = launch_configuration(kernel)
        groupsize = min(length(indices), config.groupsize)
        gridsize = cld(length(indices), groupsize)
        kernel(ys, bools, indices; groupsize, gridsize)
    end
    unsafe_free!(indices)

    return ys
end
