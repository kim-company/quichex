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
        |> process_readable_streams()  # Check for readable streams after timeout!
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
    # Always get readable streams and process them immediately
    case Native.connection_readable_streams(state.conn_resource) do
      {:ok, readable_streams} ->
        state = %{state | readable_streams: readable_streams}
        # Always read and route to handlers (immediate delivery)
        Enum.reduce(readable_streams, state, &process_one_stream/2)

      {:error, _reason} ->
        state
    end
  end

  @doc false
  defp process_one_stream(stream_id, %State{} = state) do
    case Native.connection_stream_recv(state.conn_resource, stream_id, 65535) do
      {:ok, {data, fin}} when byte_size(data) > 0 or fin ->
        Logger.debug("Stream #{stream_id}: received #{byte_size(data)} bytes, fin=#{fin}")

        # Check if this is a new incoming stream that needs a handler
        is_new_stream = not Map.has_key?(state.streams, stream_id)
        has_handler = Map.has_key?(state.stream_handlers, stream_id)
        # ALWAYS spawn handler for new streams (Connection will use MessageHandler if no user handler)
        should_spawn_handler = is_new_stream and not has_handler

        # Update stream state
        {stream, state} = State.get_or_create_stream(state, stream_id, :bidirectional)

        stream =
          stream
          |> StreamState.add_bytes_received(byte_size(data))
          |> (fn s -> if fin, do: StreamState.mark_fin_received(s), else: s end).()

        state = State.update_stream(state, stream)

        # If this is a new incoming stream, spawn handler with initial data
        state =
          if should_spawn_handler do
            # Determine direction based on stream ID (odd = peer-initiated)
            direction = if rem(stream_id, 2) == 1, do: :incoming, else: :outgoing
            stream_type = :bidirectional  # TODO: detect uni vs bidi

            # Include initial data in spawn action
            spawn_action = {:spawn_stream_handler, stream_id, direction, stream_type, data, fin}
            State.add_action(state, spawn_action)
          else
            state
          end

        # Route data based on whether stream has a handler
        # Every stream should have a handler (MessageHandler if no user handler)
        cond do
          # Just spawned handler - data already included in spawn action
          should_spawn_handler ->
            state

          # Stream has a handler - route data to it
          has_handler ->
            handler_pid = Map.get(state.stream_handlers, stream_id)
            action = {:route_to_handler, handler_pid, data, fin}
            State.add_action(state, action)

          true ->
            # No handler - shouldn't happen if we always spawn handlers
            Logger.warning("Received data for stream #{stream_id} without handler - dropping data")
            state
        end

      {:ok, {_data, _fin}} ->
        # Empty data, ignore
        state

      {:error, _reason} ->
        # Could be "done" or other error - stop reading this stream
        state
    end
  end

  @doc """
  Generates pending QUIC packets that need to be sent.

  Calls the connection_send NIF repeatedly until all pending packets are collected,
  then adds a {:send_packets, packets} action to the state.
  """
  def generate_pending_packets(%State{} = state) do
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
