defmodule Quichex.StateMachine do
  @moduledoc """
  Pure functional QUIC state transitions.

  This module implements the core state machine logic for QUIC connections.
  All functions are pure - they take state and events, return new state and actions.

  The state machine doesn't perform any side effects directly. Instead, it returns
  actions that the runtime (gen_statem) will execute.

  ## State Transitions

  The main entry points are:
  - `start_handshake/1` - Initiates the handshake
  - `process_packet/2` - Processes incoming UDP packets
  - `handle_timeout/1` - Handles connection timeouts
  """

  alias Quichex.{State, StreamState, Native}
  require Logger

  @type state_result :: {:ok, State.t()} | {:error, State.t(), term()}

  @doc """
  Initiates the connection handshake.

  Generates initial packets and returns the updated state with send actions.
  """
  @spec start_handshake(State.t()) :: State.t()
  def start_handshake(%State{} = state) do
    state
    |> generate_pending_packets()
    |> schedule_timeout()
  end

  @doc """
  Processes an incoming UDP packet.

  This is the main packet processing pipeline:
  1. Pass packet to quiche for processing
  2. Check if connection became established
  3. Process readable streams (active mode)
  4. Generate response packets
  5. Schedule next timeout

  Returns updated state with pending actions.
  """
  @spec process_packet(State.t(), binary()) :: State.t()
  def process_packet(%State{} = state, packet) when is_binary(packet) do
    recv_info = %{
      from: state.peer_addr,
      to: state.local_addr
    }

    case Native.connection_recv(state.conn_resource, packet, recv_info) do
      {:ok, _bytes_read} ->
        state
        |> State.increment_packets_received()
        |> check_established()
        |> process_readable_streams()
        |> generate_pending_packets()
        |> schedule_timeout()

      {:error, "done"} ->
        # No more data to process in this packet (not an error)
        state

      {:error, reason} ->
        # Real error - mark connection as failed
        Logger.error("Packet processing error: #{inspect(reason)}")

        state
        |> State.mark_closed({:recv_error, reason})
        |> State.add_action({:stop, {:recv_error, reason}})
    end
  end

  @doc """
  Handles connection timeout event.

  Notifies quiche of the timeout and generates any packets needed.
  """
  @spec handle_timeout(State.t()) :: State.t()
  def handle_timeout(%State{} = state) do
    case Native.connection_on_timeout(state.conn_resource) do
      {:ok, _} ->
        state
        |> generate_pending_packets()
        |> schedule_timeout()

      {:error, reason} ->
        Logger.error("Timeout handling error: #{inspect(reason)}")

        state
        |> State.mark_closed({:timeout_error, reason})
        |> State.add_action({:stop, {:timeout_error, reason}})
    end
  end

  @doc """
  Opens a new stream.

  Allocates a stream ID and creates the stream state.
  Returns `{stream_id, updated_state}`.
  """
  @spec open_stream(State.t(), :bidirectional | :unidirectional) ::
          {StreamState.stream_id(), State.t()}
  def open_stream(%State{} = state, :bidirectional) do
    {stream_id, state} = State.allocate_bidi_stream(state)
    {stream, state} = State.get_or_create_stream(state, stream_id, :bidirectional)
    {stream_id, State.update_stream(state, stream)}
  end

  def open_stream(%State{} = state, :unidirectional) do
    {stream_id, state} = State.allocate_uni_stream(state)
    {stream, state} = State.get_or_create_stream(state, stream_id, :unidirectional)
    {stream_id, State.update_stream(state, stream)}
  end

  @doc """
  Sends data on a stream.

  In active mode, immediately sends data and generates packets.

  Returns `{:ok, state}` on success or `{:error, state, reason}` on failure.
  """
  @spec stream_send(State.t(), StreamState.stream_id(), binary(), boolean()) ::
          {:ok, State.t()} | {:error, State.t(), term()}
  def stream_send(%State{} = state, stream_id, data, fin) when is_binary(data) do
    case Native.connection_stream_send(state.conn_resource, stream_id, data, fin) do
      {:ok, bytes_written} ->
        # Update stream state
        {stream, state} = State.get_or_create_stream(state, stream_id, :bidirectional)

        stream =
          stream
          |> StreamState.add_bytes_sent(bytes_written)
          |> (fn s -> if fin, do: StreamState.mark_fin_sent(s), else: s end).()

        new_state =
          state
          |> State.update_stream(stream)
          |> generate_pending_packets()

        {:ok, new_state}

      {:error, reason} ->
        # This is expected behavior (e.g., sending after fin or shutdown)
        # Log at debug level, not error
        Logger.debug("Stream send failed on stream #{stream_id}: #{inspect(reason)}")
        {:error, state, reason}
    end
  end

  @doc """
  Receives data from a stream (passive mode).

  Reads from the NIF and returns the data. Does not buffer.
  """
  @spec stream_recv(State.t(), StreamState.stream_id(), pos_integer()) ::
          {{:ok, binary(), boolean()}, State.t()} | {{:error, term()}, State.t()}
  def stream_recv(%State{} = state, stream_id, max_len) do
    # First check if there's buffered data (passive mode)
    {stream, state} = State.get_or_create_stream(state, stream_id, :bidirectional)

    case StreamState.drain_buffer(stream, max_len) do
      {[], ^stream} ->
        # No buffered data, read from NIF
        case Native.connection_stream_recv(state.conn_resource, stream_id, max_len) do
          {:ok, {data, fin}} ->
            stream =
              stream
              |> StreamState.add_bytes_received(byte_size(data))
              |> (fn s -> if fin, do: StreamState.mark_fin_received(s), else: s end).()

            state = State.update_stream(state, stream)
            {{:ok, data, fin}, state}

          {:error, reason} ->
            {{:error, reason}, state}
        end

      {buffer_data, updated_stream} ->
        # Return buffered data
        # Combine all buffered chunks
        {combined_data, any_fin} =
          Enum.reduce(buffer_data, {<<>>, false}, fn {data, fin}, {acc_data, acc_fin} ->
            {acc_data <> data, acc_fin or fin}
          end)

        state = State.update_stream(state, updated_stream)
        {{:ok, combined_data, any_fin}, state}
    end
  end

  @doc """
  Shuts down a stream in the specified direction.
  """
  @spec stream_shutdown(State.t(), StreamState.stream_id(), :read | :write | :both, non_neg_integer()) ::
          State.t()
  def stream_shutdown(%State{} = state, stream_id, direction, error_code)
      when direction in [:read, :write, :both] do
    direction_str =
      case direction do
        :read -> "read"
        :write -> "write"
        :both -> "both"
      end

    case Native.connection_stream_shutdown(state.conn_resource, stream_id, direction_str, error_code) do
      {:ok, _} ->
        generate_pending_packets(state)

      {:error, reason} ->
        Logger.warning("Stream shutdown error on stream #{stream_id}: #{inspect(reason)}")
        state
    end
  end

  # Private Functions

  @doc false
  defp check_established(%State{established: true} = state), do: state

  defp check_established(%State{established: false} = state) do
    case Native.connection_is_established(state.conn_resource) do
      {:ok, true} ->
        Logger.debug("Connection established")

        action = {:send_to_app, state.controlling_process, {:quic_connected, self()}}

        state
        |> State.mark_established()
        |> State.reply_to_waiters(:ok)
        |> State.add_action(action)

      _ ->
        state
    end
  end

  @doc false
  defp process_readable_streams(%State{} = state) do
    # Always get readable streams to update our tracking
    case Native.connection_readable_streams(state.conn_resource) do
      {:ok, readable_streams} ->
        state = %{state | readable_streams: readable_streams}

        if State.should_deliver_messages?(state) do
          # Active mode: read and deliver messages
          Enum.reduce(readable_streams, state, &process_one_stream/2)
        else
          # Passive mode: just update the readable list, don't read
          # Buffer the stream IDs for later explicit recv
          state
        end

      {:error, _reason} ->
        state
    end
  end

  @doc false
  defp process_one_stream(stream_id, %State{} = state) do
    case Native.connection_stream_recv(state.conn_resource, stream_id, 65535) do
      {:ok, {data, fin}} when byte_size(data) > 0 or fin ->
        Logger.debug("Stream #{stream_id}: received #{byte_size(data)} bytes, fin=#{fin}")

        # Update stream state
        {stream, state} = State.get_or_create_stream(state, stream_id, :bidirectional)

        stream =
          stream
          |> StreamState.add_bytes_received(byte_size(data))
          |> (fn s -> if fin, do: StreamState.mark_fin_received(s), else: s end).()

        state = State.update_stream(state, stream)

        cond do
          state.active == true or state.active == :once ->
            # Send message and maybe decrement count
            actions = [
              {:send_to_app, state.controlling_process, {:quic_stream, self(), stream_id, data}}
            ]

            actions =
              if fin do
                [{:send_to_app, state.controlling_process, {:quic_stream_fin, self(), stream_id}} | actions]
              else
                actions
              end

            state = State.add_actions(state, actions)

            # Decrement active count if needed
            if state.active == :once or is_integer(state.active) do
              State.decrement_active_count(state)
            else
              state
            end

          is_integer(state.active) and state.active_count > 0 ->
            # Send message and decrement
            actions = [
              {:send_to_app, state.controlling_process, {:quic_stream, self(), stream_id, data}}
            ]

            actions =
              if fin do
                [{:send_to_app, state.controlling_process, {:quic_stream_fin, self(), stream_id}} | actions]
              else
                actions
              end

            state
            |> State.add_actions(actions)
            |> State.decrement_active_count()

          true ->
            # Passive mode: buffer the data
            stream = StreamState.buffer_data(stream, data, fin)
            State.update_stream(state, stream)
        end

      {:ok, {_data, _fin}} ->
        # Empty data, ignore
        state

      {:error, _reason} ->
        # Could be "done" or other error - stop reading this stream
        state
    end
  end

  @doc false
  defp generate_pending_packets(%State{} = state) do
    collect_packets_recursive(state, [])
  end

  defp collect_packets_recursive(state, acc_packets) do
    case Native.connection_send(state.conn_resource) do
      {:ok, {packet, send_info}} ->
        collect_packets_recursive(state, [{packet, send_info} | acc_packets])

      {:error, "done"} ->
        if acc_packets != [] do
          packets = Enum.reverse(acc_packets)
          action = {:send_packets, packets}

          state
          |> State.increment_packets_sent(length(packets))
          |> State.add_action(action)
        else
          state
        end

      {:error, _reason} ->
        state
    end
  end

  @doc false
  defp schedule_timeout(%State{} = state) do
    case Native.connection_timeout(state.conn_resource) do
      {:ok, timeout_ms} when is_integer(timeout_ms) ->
        action = {:schedule_timeout, timeout_ms}
        State.add_action(state, action)

      _ ->
        state
    end
  end
end
