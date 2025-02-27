# Key: context (device), fft type (fwd, inv), xdims, x eltype, inplace or not, region.
const HandleCacheKey = Tuple{HIPContext, rocfft_transform_type, Dims, Type, Bool, Any}
# Value: plan, worksize.
const HandleCacheValue = Tuple{rocfft_plan, Int}
const IDLE_HANDLES = HandleCache{HandleCacheKey, HandleCacheValue}()

function get_plan(args...)
    rocfft_setup_once()
    handle, worksize = pop!(IDLE_HANDLES, (AMDGPU.context(), args...)) do
        create_plan(args...)
    end
    workarea = ROCVector{Int8}(undef, worksize)
    return handle, workarea
end

function create_plan(xtype::rocfft_transform_type, xdims, T, inplace, region)
    precision = (real(T) == Float64) ?
        rocfft_precision_double : rocfft_precision_single
    placement = inplace ?
        rocfft_placement_inplace : rocfft_placement_notinplace

    nrank = length(region)
    sz = [xdims[i] for i in region]
    csz = copy(sz)
    csz[1] = sz[1] ÷ 2 + 1
    batch = prod(xdims) ÷ prod(sz)

    handle_ref = Ref{rocfft_plan}()
    worksize_ref = Ref{Csize_t}()
    if batch == 1
        rocfft_plan_create(
            handle_ref, placement, xtype, precision, nrank, sz, 1, C_NULL)
    else
        plan_desc_ref = Ref{rocfft_plan_description}()
        rocfft_plan_description_create(plan_desc_ref)
        description = plan_desc_ref[]

        if xtype == rocfft_transform_type_real_forward
            in_array_type = rocfft_array_type_real
            # TODO: output to full array
            out_array_type = rocfft_array_type_hermitian_interleaved
        elseif xtype == rocfft_transform_type_real_inverse
            # TODO: also for complex_interleaved
            in_array_type = rocfft_array_type_hermitian_interleaved
            out_array_type = rocfft_array_type_real
        else
            in_array_type = rocfft_array_type_complex_interleaved
            out_array_type = rocfft_array_type_complex_interleaved
        end

        # FIXME: gives out-of-bounds errors on real2complex: region=(1,) for 2D input
        if ((region...,) == ((1:nrank)...,))
            # handle simple case ... simply! (for robustness)
            rocfft_plan_description_set_data_layout(
                description, in_array_type, out_array_type,
                C_NULL, C_NULL,
                nrank, C_NULL, 0,
                nrank, C_NULL, 0)
            rocfft_plan_create(
                handle_ref, placement, xtype, precision,
                nrank, sz, batch, description)
        else
            if nrank > 1
                # TODO restrict to all(diff(region) .== 1),
                #   since rocFFT fails with inverse non contiguous regions?
                any(diff(collect(region)) .< 1) && throw(ArgumentError(
                    "`region` must be an increasing sequence, instead: `$region`."))
                any(region .< 1 .|| region .> length(xdims)) && throw(ArgumentError(
                    "`region` can only refer to valid dimensions `$xdims`, instead `$region`."))
            end

            cdims = collect(xdims)
            cdims[region[1]] = div(cdims[region[1]], 2) + 1

            strides = [prod(xdims[1:region[k] - 1]) for k in 1:nrank]
            real_strides = [prod(cdims[1:region[k] - 1]) for k in 1:nrank]

            if nrank == 1 || all(diff(collect(region)) .== 1)
                # _stride: successive elements in dimension of region
                # _dist: distance between first elements of batches
                if region[1] == 1
                    idist = prod(sz)
                    cdist = prod(csz)
                else
                    region[end] != length(xdims) && throw(ArgumentError(
                        "batching dims must be sequential"))
                    idist = 1
                    cdist = 1
                end

                ostrides = copy(strides)
                istrides = copy(strides)
                if xtype == rocfft_transform_type_real_forward
                    odist = cdist
                    ostrides .= real_strides
                else
                    odist = idist
                end
                if xtype == rocfft_transform_type_real_inverse
                    idist = cdist
                    istrides .= real_strides
                end
            else
                if region[1] == 1
                    ii = 1
                    while (ii < nrank) && (region[ii] == region[ii + 1] - 1)
                        ii += 1
                    end
                    idist = prod(xdims[1:ii])
                    cdist = prod(cdims[1:ii])
                    ngaps = 0
                else
                    istride = prod(xdims[1:region[1] - 1])
                    idist = 1
                    cdist = 1
                    ngaps = 1
                end
                nem = ones(Int, nrank)
                cem = ones(Int, nrank)

                id = 1
                for ii in 1:nrank - 1
                    if region[ii + 1] > region[ii] + 1
                        ngaps += 1
                    end

                    while id < region[ii + 1]
                        nem[ii] *= xdims[id]
                        cem[ii] *= cdims[id]
                        id += 1
                    end
                    @assert nem[ii] >= sz[ii]
                end
                if region[end] < length(xdims)
                    ngaps += 1
                end

                # CUFFT represents batches by a single stride (_dist)
                # ROCFFT can have multiple strides,
                # but non sequential batch dims are also not working
                # so we must verify that region is consistent with this:
                ngaps > 1 && throw(ArgumentError("batch regions must be sequential"))

                ostrides = copy(strides)
                istrides = copy(strides)
                if xtype == rocfft_transform_type_real_forward
                    odist = cdist
                    ostrides .= real_strides
                else
                    odist = idist
                end

                if xtype == rocfft_transform_type_real_inverse
                    idist = cdist
                    istrides .= real_strides
                end
            end

            rocfft_plan_description_set_data_layout(
                description, in_array_type, out_array_type, C_NULL, C_NULL,
                length(istrides), istrides, idist,
                length(ostrides), ostrides, odist)
            rocfft_plan_create(
                handle_ref, placement, xtype, precision,
                nrank, sz, batch, description)
        end
        rocfft_plan_description_destroy(description)
    end
    rocfft_plan_get_work_buffer_size(handle_ref[], worksize_ref)
    return handle_ref[], Int(worksize_ref[])
end

function release_plan(plan)
    push!(IDLE_HANDLES, plan) do
        unsafe_free!(plan)
    end
end
