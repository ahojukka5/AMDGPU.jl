const DEFAULT_HOSTCALL_TIMEOUT = Ref{Union{Float64, Nothing}}(nothing)
const DEFAULT_HOSTCALL_LATENCY = Ref{Float64}(0.01)

include("hostcall_signal_helpers.jl")

"""
    HostCall{RT,AT}

GPU-compatible struct for making hostcalls.
"""
struct HostCall{RT,AT,S}
    state::StateMachine{HostCallState,S}
    buf_ptr::LLVMPtr{UInt8,AS.Global}
    buf_len::UInt
end

function HostCall(RT::Type, AT::Type{<:Tuple}, state::StateMachine{HostCallState,ROCSignal};
                  device=AMDGPU.default_device(), buf_len=nothing)
    if isnothing(buf_len)
        buf_len = 0
        for T in AT.parameters
            @assert isbitstype(T) "Hostcall arguments must be bits-type"
            buf_len += sizeof(T)
        end
    end

    buf_len = max(sizeof(UInt64), buf_len) # make room for return buffer pointer
    buf = Mem.alloc(device, buf_len; coherent=true)
    buf_ptr = LLVMPtr{UInt8,AS.Global}(Base.unsafe_convert(Ptr{UInt8}, buf))
    state = StateMachine{HostCallState,UInt64}(state.signal.signal[].handle)
    return HostCall{RT,AT,UInt64}(state, buf_ptr, buf_len)
end

Adapt.adapt_storage(::AMDGPU.Runtime.Adaptor, hc::HostCall{RT,AT,ROCSignal}) where {RT,AT} =
    HostCall{RT,AT,UInt64}(StateMachine{HostCallState,UInt64}(hc.state.signal.signal[].handle),
                           hc.buf_ptr, hc.buf_len)

"Calls the host function stored in `hc` with arguments `args`."
@inline function hostcall!(hc::HostCall, args...)
    hostcall!(Val{:group}(), hc, args...)
end

@inline function hostcall!(
    ::Val{mode}, hc::HostCall{RT, AT}, args...,
) where {mode, RT, AT}
    hostcall_device_lock!(Val{mode}(), hc)
    hostcall_device_write_args!(Val{mode}(), hc, args...)
    return hostcall_device_trigger_and_return!(Val{mode}(), hc)
end

#= TODO: Requires some dynamically-allocated per-kernel memory
macro elect_grid_lane()
    @gensym lock_name
    quote
        election_lock = alloc_local_zeroinit($(QuoteNode(lock_name)), Int64, 1)
        atomic_cas!(election_lock, 0, workitemIdx().x)
    end
end
=#
macro elect_workgroup_lane()
    @gensym idx lock_name lock_prev election_lock
    quote
        $idx = workitemIdx().x
        $election_lock = alloc_local($(QuoteNode(lock_name)), Int64, 1, true)
        $lock_prev = atomic_cas!($election_lock, 0, $idx)
        (;is_leader=($lock_prev == 0), prev=$lock_prev, lock=$election_lock)
    end
end
function reset_election!(lock)
    leader = unsafe_load(lock)
    atomic_store!(lock, 0)
end
macro device_execution_gate(mode, exec_ex)
    if mode isa QuoteNode
        mode = mode.value::Symbol
    end
    @assert mode in (:grid, :group, :wave, :lane) "Invalid mode: $mode"
    ex = Expr(:block)
    @gensym election
    if mode == :grid
        push!(ex.args, quote
            # Must be on first item of first group
            # FIXME: Elect one lane out of the grid
            # FIXME: if !@elect_grid_lane()
            if $workgroupIdx().x != 1 || $workitemIdx().x != 1
                @goto gated_done
            end
        end)
    elseif mode == :group
        push!(ex.args, quote
            # Must be on first active item of each group
            $election = AMDGPU.Device.@elect_workgroup_lane()
            if !$election.is_leader
                @goto gated_done
            end
        end)
    elseif mode == :wave
        push!(ex.args, quote
            # Must be on first lane of each wavefront of each group
            let idx = $workitemIdx().x
                if idx != $readfirstlane(Base.unsafe_trunc(Int32, idx))
                    @goto gated_done
                end
            end
        end)
    end
    push!(ex.args, quote
        $(esc(exec_ex))
        @label gated_done
    end)
    if mode == :group
        push!(ex.args, quote
            # Reset election lock
            $reset_election!($election.lock)
        end)
    end
    return ex
end

@inline function hostcall_device_lock!(hc::HostCall)
    hostcall_device_lock!(Val{:group}(), hc)
end

@inline @generated function hostcall_device_lock!(
    ::Val{mode}, hc::HostCall,
) where mode
    return quote
        @device_execution_gate $mode begin
            # Acquire lock on hostcall buffer
            hostcall_transition_wait!(hc.state, READY_SENTINEL, DEVICE_LOCK_SENTINEL)
        end
    end
end

@inline function hostcall_device_write_args!(hc::HostCall, args...)
    hostcall_device_write_args!(Val{:group}(), hc, args...)
end

@inline @generated function hostcall_device_write_args!(
    ::Val{mode}, hc::HostCall{RT, AT}, args...,
) where {mode, RT, AT}
    ex = Expr(:block)

    # Copy arguments into buffer
    # Modified from CUDAnative src/device/cuda/dynamic_parallelism.jl
    off = 1
    for i in 1:length(args)
        T = args[i]
        sz = sizeof(T)
        # FIXME: Use proper alignment
        ptr = :(reinterpret(LLVMPtr{$T,AS.Global}, hc.buf_ptr+$off-1))
        push!(ex.args, :(Base.unsafe_store!($ptr, args[$i])))
        off += sz
    end

    return macroexpand(@__MODULE__, quote
        @device_execution_gate $mode begin
            $ex
        end
    end)
end

@inline function hostcall_device_trigger_and_return!(hc::HostCall)
    hostcall_device_trigger_and_return!(Val{:group}(), hc::HostCall)
end

@inline @generated function hostcall_device_trigger_and_return!(::Val{mode}, hc::HostCall{RT, AT}) where {mode, RT, AT}
    ex = Expr(:block)
    @gensym shmem buf_ptr ret_ptr hostcall_return

    push!(ex.args, quote
        if $RT !== Nothing
            # FIXME: This is not valid without the @inline
            # $shmem = $alloc_local($hostcall_return, $RT, 1)
            # But this is fine (if slower)
            $shmem = $get_global_pointer($(Val{hostcall_return}()), $RT)
        end

        @device_execution_gate $mode begin
            # Ensure arguments are written
            $hostcall_transition_wait!(hc.state, $DEVICE_LOCK_SENTINEL, $DEVICE_MSG_SENTINEL)
            # Wait on host message
            $hostcall_waitfor(hc.state, $HOST_MSG_SENTINEL)
            # Get return buffer and load first value
            if $RT !== Nothing
                $buf_ptr = reinterpret(LLVMPtr{LLVMPtr{$RT,AS.Global},AS.Global},hc.buf_ptr)
                $ret_ptr = unsafe_load($buf_ptr)
                if UInt64($ret_ptr) == 0
                    hc.state[] = $DEVICE_ERR_SENTINEL
                    $signal_exception()
                    $trap()
                end
                unsafe_store!($shmem, unsafe_load($ret_ptr)::$RT)
            end
            hc.state[] = $READY_SENTINEL
        end
        if $RT !== Nothing
            return unsafe_load($shmem)
        else
            return nothing
        end
    end)

    return ex
end

@inline @generated function hostcall_device_args_size(args...)
    sz = 0
    for arg in args
        sz += sizeof(arg)
    end
    return sz
end

@generated function hostcall_host_read_args(hc::HostCall{RT,AT}) where {RT,AT}
    ex = Expr(:tuple)

    # Copy arguments into buffer
    off = 1
    for i in 1:length(AT.parameters)
        T = AT.parameters[i]
        sz = sizeof(T)
        # FIXME: Use correct alignment
        push!(ex.args, quote
            lref = Ref{$T}()
            HSA.memory_copy(reinterpret(Ptr{Cvoid}, Base.unsafe_convert(Ptr{$T}, lref)),
                            reinterpret(Ptr{Cvoid}, hc.buf_ptr+$off - 1),
                            $sz) |> Runtime.check
            lref[]
        end)
        off += sz
    end

    return ex
end

struct HostCallException <: Exception
    reason::String
    err::Union{Exception, Nothing}
    bt::Union{Vector, Nothing}
end

HostCallException(reason) = HostCallException(reason, nothing, backtrace())

HostCallException(reason, err) = HostCallException(reason, err, catch_backtrace())

function Base.showerror(io::IO, err::HostCallException)
    print(io, "HostCallException: $(err.reason)")
    if err.err !== nothing || err.bt !== nothing
        print(io, ":\n")
    end
    err.err !== nothing && Base.showerror(io, err.err)
    err.bt !== nothing && Base.show_backtrace(io, err.bt)
end

const NAMED_PERDEVICE_HOSTCALLS = Dict{Runtime.ROCDevice, Dict{Symbol, HostCall}}()

function named_perdevice_hostcall(func, device::Runtime.ROCDevice, name::Symbol)
    lock(Runtime.RT_LOCK) do
        hcs = get!(()->Dict{Symbol, HostCall}(), NAMED_PERDEVICE_HOSTCALLS, device)
        return get!(func, hcs, name)
    end
end

"""
    HostCall(func, return_type::Type, arg_types::Type{Tuple}) -> HostCall

Construct a `HostCall` that executes `func` with the arguments passed from the
calling kernel. `func` must be passed arguments of types contained in
`arg_types`, and must return a value of type `return_type`, or else the
hostcall will fail with undefined behavior.

Note: This API is currently experimental and is subject to change at any time.
"""
function HostCall(func::Base.Callable, rettype::Type, argtypes::Type{<:Tuple}; return_task::Bool = false,
                  device=AMDGPU.default_device(), maxlat=DEFAULT_HOSTCALL_LATENCY[],
                  timeout=nothing, continuous=false, buf_len=nothing)
    signal = Runtime.ROCSignal()
    state = StateMachine(HostCallState, signal, READY_SENTINEL)
    hc = HostCall(rettype, argtypes, state; device, buf_len)

    tsk = Threads.@spawn begin
        ret_buf = Ref{Mem.Buffer}()
        ret_len = 0
        try
            while true
                if !hostcall_host_wait(signal.signal[]; maxlat=maxlat, timeout=timeout)
                    throw(HostCallException("Hostcall: Timeout on signal $signal"))
                end
                if length(argtypes.parameters) > 0
                    args = try
                        hostcall_host_read_args(hc)
                    catch err
                        throw(HostCallException("Error getting arguments", err))
                    end
                    @debug "Hostcall: Got arguments of length $(length(args))"
                else
                    args = ()
                end
                ret = try
                    func(args...,)
                catch err
                    throw(HostCallException("Error executing host function", err))
                end
                if typeof(ret) != rettype
                    throw(HostCallException("Host function result of wrong type: $(typeof(ret)), expected $rettype"))
                end
                if !isbits(ret)
                    throw(HostCallException("Host function result not isbits: $(typeof(ret))"))
                end
                @debug "Hostcall: Host function returning value of type $(typeof(ret))"
                try
                    if isassigned(ret_buf) && (ret_len < sizeof(ret))
                        Mem.free(ret_buf[])
                        ret_len = sizeof(ret)
                        ret_buf[] = Mem.alloc(device, ret_len; coherent=true)
                    elseif !isassigned(ret_buf)
                        ret_len = sizeof(ret)
                        ret_buf[] = Mem.alloc(device, ret_len; coherent=true)
                    end
                    ret_ref = Ref{rettype}(ret)
                    GC.@preserve ret_ref begin
                        ret_ptr = Base.unsafe_convert(Ptr{Cvoid}, ret_buf[])
                        if sizeof(ret) > 0
                            src_ptr = reinterpret(Ptr{Cvoid}, Base.unsafe_convert(Ptr{rettype}, ret_ref))
                            HSA.memory_copy(ret_ptr, src_ptr, sizeof(ret)) |> Runtime.check
                        end

                        args_buf_ptr = reinterpret(Ptr{Ptr{Cvoid}}, hc.buf_ptr)
                        unsafe_store!(args_buf_ptr, ret_ptr)
                    end
                    host_signal_store!(signal.signal[], HOST_MSG_SENTINEL)
                catch err
                    throw(HostCallException("Error returning hostcall result", err))
                end
                @debug "Hostcall: Host function return completed"
                continuous || break
            end
        catch err
            # Gracefully terminate all waiters
            host_signal_store!(signal.signal[], HOST_ERR_SENTINEL)
            if err isa EOFError
                # If EOF, then Julia is exiting, no need to re-throw.
            else
                @error "HostCall error" exception=(err,catch_backtrace())
                rethrow(err)
            end
        finally
            # We need to free the memory buffers, but first we need to ensure that
            # the device has read from these buffers. Therefore we wait either for
            # READY_SENTINEL or else an error signal.
            while !Runtime.RT_EXITING[]
                prev = host_signal_load(signal.signal[])
                if prev == READY_SENTINEL || prev == HOST_ERR_SENTINEL || prev == DEVICE_ERR_SENTINEL
                    if isassigned(ret_buf)
                        Mem.free(ret_buf[])
                    end
                    buf_ptr = reinterpret(Ptr{Cvoid}, hc.buf_ptr)
                    Mem.free(Mem.Buffer(buf_ptr, C_NULL, buf_ptr, 0, device, true, false))
                    break
                end
            end
        end
    end

    if return_task
        return hc, tsk
    else
        return hc
    end
end

function hostcall_host_wait(signal_handle::HSA.Signal; maxlat=DEFAULT_HOSTCALL_LATENCY[], timeout=DEFAULT_HOSTCALL_TIMEOUT[])
    @debug "Hostcall: Waiting on signal $signal_handle"
    start_time = time_ns()
    while !Runtime.RT_EXITING[]
        prev = host_signal_load(signal_handle)
        if prev == DEVICE_MSG_SENTINEL
            prev = host_signal_cmpxchg!(
                signal_handle, DEVICE_MSG_SENTINEL, HOST_LOCK_SENTINEL)
            if prev == DEVICE_MSG_SENTINEL
                @debug "Hostcall: Device message on signal $signal_handle"
                return true
            end
        elseif prev == DEVICE_ERR_SENTINEL
            @debug "Hostcall: Device error on signal $signal_handle"
            throw(HostCallException("Device error on signal $signal_handle"))
        end

        if timeout !== nothing
            now_time = time_ns()
            diff_time = (now_time - start_time) / 10^9
            if diff_time > timeout
                @debug "Hostcall: Signal wait timeout on signal $signal_handle"
                return false
            end
        end
        sleep(maxlat)
    end
end
