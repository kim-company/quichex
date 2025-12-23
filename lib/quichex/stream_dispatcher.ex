defmodule Quichex.StreamDispatcher do
  @moduledoc """
  Routes stream operations to workers or handles inline.

  This module implements the core concurrency strategy for QUIC streams:
  - Small transfers (< threshold): handled inline in connection process
  - Large transfers or long-lived streams: delegated to StreamWorker processes

  This allows stream operations to run in parallel while the main connection
  process handles packet batching and protocol state.
  """

  alias Quichex.{State, StreamState, StreamWorker, StateMachine}

  @doc """
  Send data on a stream.

  Decides whether to handle inline or delegate to a worker process based on:
  - Data size
  - Stream worker threshold configuration
  - Current number of active workers
  - Connection mode (:http, :webtransport, :auto)

  Returns `{:ok, state}` on success or `{:error, state, reason}` on failure.
  """
  @spec send(State.t(), StreamState.stream_id(), binary(), boolean()) ::
          {:ok, State.t()} | {:error, State.t(), term()}
  def send(state, stream_id, data, fin) when is_binary(data) do
    case routing_decision(state, stream_id, data) do
      :inline ->
        # Small transfer, handle directly in connection process
        send_inline(state, stream_id, data, fin)

      :worker ->
        # Large transfer or streaming, delegate to worker
        send_via_worker(state, stream_id, data, fin)
    end
  end

  @doc """
  Receive data from a stream.

  Checks buffer first (for passive mode), then delegates to NIF if needed.
  """
  @spec recv(State.t(), StreamState.stream_id(), non_neg_integer()) ::
          {{:ok, binary(), boolean()} | {:error, term()}, State.t()}
  def recv(state, stream_id, max_len) do
    stream = Map.get(state.streams, stream_id)

    if stream && StreamState.has_buffered_data?(stream) do
      # Return buffered data (passive mode)
      {drained_entries, updated_stream} = StreamState.drain_buffer(stream, max_len)

      # Combine drained entries into a single binary
      {data, final_fin} =
        Enum.reduce(drained_entries, {<<>>, false}, fn {chunk, fin}, {acc_data, _acc_fin} ->
          {acc_data <> chunk, fin}
        end)

      new_state = State.update_stream(state, updated_stream)
      {{:ok, data, final_fin}, new_state}
    else
      # No buffered data, read from NIF
      case Quichex.Native.connection_stream_recv(state.conn_resource, stream_id, max_len) do
        {:ok, {data, fin}} ->
          # Update stream state
          {stream, state} = State.get_or_create_stream(state, stream_id, :bidirectional)
          stream = StreamState.add_bytes_received(stream, byte_size(data))
          stream = if fin, do: StreamState.mark_fin_received(stream), else: stream
          new_state = State.update_stream(state, stream)
          {{:ok, data, fin}, new_state}

        {:error, reason} ->
          {{:error, reason}, state}
      end
    end
  end

  # Private Functions

  @doc false
  defp routing_decision(state, _stream_id, data) do
    data_size = byte_size(data)
    threshold = Map.get(state.config || %{}, :stream_worker_threshold, 65536)
    max_workers = Map.get(state.config || %{}, :max_stream_workers, 100)
    active_workers = map_size(state.stream_workers)

    cond do
      # Always inline for small transfers (< 64KB by default)
      data_size < threshold ->
        :inline

      # Don't spawn workers if we hit max limit
      active_workers >= max_workers ->
        :inline

      # Large transfer - use worker
      true ->
        :worker
    end
  end

  @doc false
  defp send_inline(state, stream_id, data, fin) do
    # Directly call NIF (inline in connection process)
    case Quichex.Native.connection_stream_send(state.conn_resource, stream_id, data, fin) do
      {:ok, bytes_written} ->
        # Update stream state
        {stream, state} = State.get_or_create_stream(state, stream_id, :bidirectional)

        stream =
          stream
          |> StreamState.add_bytes_sent(bytes_written)
          |> then(fn s -> if fin, do: StreamState.mark_fin_sent(s), else: s end)

        new_state =
          state
          |> State.update_stream(stream)
          |> StateMachine.generate_pending_packets()

        {:ok, new_state}

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  @doc false
  defp send_via_worker(state, stream_id, data, fin) do
    case get_or_spawn_worker(state, stream_id) do
      {:ok, worker_pid, new_state} ->
        # Delegate to worker process
        case StreamWorker.async_send(worker_pid, data, fin) do
          :ok ->
            {:ok, new_state}

          {:error, reason} ->
            # Worker failed, clean up and return error
            new_state = remove_stream_worker(new_state, stream_id)
            {:error, new_state, reason}
        end

      {:error, reason} ->
        {:error, state, reason}
    end
  end

  @doc false
  defp get_or_spawn_worker(state, stream_id) do
    case Map.get(state.stream_workers, stream_id) do
      nil ->
        # Spawn new worker
        spawn_worker(state, stream_id)

      pid when is_pid(pid) ->
        # Reuse existing worker
        if Process.alive?(pid) do
          {:ok, pid, state}
        else
          # Worker died, clean up and spawn new one
          state = remove_stream_worker(state, stream_id)
          spawn_worker(state, stream_id)
        end
    end
  end

  @doc false
  defp spawn_worker(state, stream_id) do
    case StreamWorker.start_link(
           conn_resource: state.conn_resource,
           stream_id: stream_id,
           parent_pid: self()
         ) do
      {:ok, pid} ->
        new_state = add_stream_worker(state, stream_id, pid)
        {:ok, pid, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  defp add_stream_worker(state, stream_id, pid) do
    %{state | stream_workers: Map.put(state.stream_workers, stream_id, pid)}
  end

  @doc false
  defp remove_stream_worker(state, stream_id) do
    %{state | stream_workers: Map.delete(state.stream_workers, stream_id)}
  end
end
