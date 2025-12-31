defmodule Quichex.State do
  @moduledoc """
  Pure functional QUIC connection state.

  This module defines the complete state for a QUIC connection, including:
  - Connection resource (NIF reference to quiche connection)
  - Network addresses (local and peer)
  - Stream states

  All state transformations are pure functions that return updated state.

  ## Socket Mode

  The UDP socket is always in `{active, true}` mode for minimum latency.
  Socket notifications sent immediately - no buffering.
  """

  alias Quichex.StreamState

  @type workload_mode :: :http | :webtransport | :auto
  @type connection_mode :: :client | :server

  @type t :: %__MODULE__{
          # Core connection state
          conn_resource: reference() | nil,
          connection_mode: connection_mode(),
          local_addr: {tuple(), :inet.port_number()} | nil,
          peer_addr: {tuple(), :inet.port_number()} | nil,
          config: Quichex.Config.t() | nil,
          socket: :gen_udp.socket() | nil,
          scid: binary() | nil,
          dcid: binary() | nil,
          listener_pid: pid() | nil,
          server_name: String.t() | nil,

          # Process management
          controlling_process: pid() | nil,
          waiters: [:gen_statem.from()],

          # Handler system
          handler_module: module() | nil,
          handler_state: term() | nil,

          # Connection lifecycle
          established: boolean(),
          closed: boolean(),
          close_reason: term() | nil,

          # Stream management
          next_bidi_stream: non_neg_integer(),
          next_uni_stream: non_neg_integer(),
          streams: %{StreamState.stream_id() => StreamState.t()},
          readable_streams: [StreamState.stream_id()],
          # Partial sends tracking (for flow control handling)
          partial_sends: %{StreamState.stream_id() => {binary(), boolean()}},
          # Send queues for each stream (FIFO queue of pending sends)
          send_queues: %{StreamState.stream_id() => :queue.queue({binary(), boolean()})},

          # Timeout management
          timeout_ref: reference() | nil,

          # Configuration
          mode: workload_mode(),
          stream_recv_buffer_size: non_neg_integer(),

          # Statistics
          packets_sent: non_neg_integer(),
          packets_received: non_neg_integer(),
          bytes_sent: non_neg_integer(),
          bytes_received: non_neg_integer()
        }

  defstruct conn_resource: nil,
            connection_mode: :client,
            local_addr: nil,
            peer_addr: nil,
            config: nil,
            socket: nil,
            scid: nil,
            dcid: nil,
            listener_pid: nil,
            server_name: nil,
            controlling_process: nil,
            waiters: [],
            handler_module: nil,
            handler_state: nil,
            established: false,
            closed: false,
            close_reason: nil,
            next_bidi_stream: 0,
            next_uni_stream: 0,
            streams: %{},
            readable_streams: [],
            partial_sends: %{},
            send_queues: %{},
            timeout_ref: nil,
            mode: :auto,
            stream_recv_buffer_size: 16384,
            packets_sent: 0,
            packets_received: 0,
            bytes_sent: 0,
            bytes_received: 0

  @doc """
  Creates a new connection state.

  ## Options

    * `:server_name` - Server name for SNI (default: `nil`)
    * `:mode` - Workload mode: `:http`, `:webtransport`, or `:auto` (default: `:auto`)
    * `:stream_recv_buffer_size` - Maximum bytes to read per stream_recv call (default: `65536`)

  ## Examples

      iex> State.new(conn_resource, socket, local_addr, peer_addr, config)
      %State{conn_resource: #Reference<...>, ...}
  """
  @spec new(reference(), :gen_udp.socket(), tuple(), tuple(), Quichex.Config.t(), keyword()) ::
          t()
  def new(conn_resource, socket, local_addr, peer_addr, config, opts \\ []) do
    %__MODULE__{
      conn_resource: conn_resource,
      socket: socket,
      local_addr: local_addr,
      peer_addr: peer_addr,
      config: config,
      server_name: Keyword.get(opts, :server_name),
      mode: Keyword.get(opts, :mode, :auto),
      stream_recv_buffer_size: Keyword.get(opts, :stream_recv_buffer_size, 16384)
    }
  end

  @doc """
  Gets or creates a stream state.
  """
  @spec get_or_create_stream(t(), StreamState.stream_id(), StreamState.stream_type()) ::
          {StreamState.t(), t()}
  def get_or_create_stream(%__MODULE__{} = state, stream_id, type) do
    case Map.get(state.streams, stream_id) do
      nil ->
        stream = StreamState.new(stream_id, type)
        {stream, put_in(state.streams[stream_id], stream)}

      stream ->
        {stream, state}
    end
  end

  @doc """
  Updates a stream state.
  """
  @spec update_stream(t(), StreamState.t()) :: t()
  def update_stream(%__MODULE__{} = state, %StreamState{stream_id: stream_id} = stream) do
    put_in(state.streams[stream_id], stream)
  end

  @doc """
  Allocates a new bidirectional stream ID.

  Client-initiated: stream_id % 4 == 0
  Server-initiated: stream_id % 4 == 1
  """
  @spec allocate_bidi_stream(t()) :: {StreamState.stream_id(), t()}
  def allocate_bidi_stream(%__MODULE__{next_bidi_stream: next, connection_mode: mode} = state) do
    offset = if mode == :server, do: 1, else: 0
    stream_id = next * 4 + offset
    {stream_id, %{state | next_bidi_stream: next + 1}}
  end

  @doc """
  Allocates a new unidirectional stream ID.

  Client-initiated: stream_id % 4 == 2
  Server-initiated: stream_id % 4 == 3
  """
  @spec allocate_uni_stream(t()) :: {StreamState.stream_id(), t()}
  def allocate_uni_stream(%__MODULE__{next_uni_stream: next, connection_mode: mode} = state) do
    offset = if mode == :server, do: 3, else: 2
    stream_id = next * 4 + offset
    {stream_id, %{state | next_uni_stream: next + 1}}
  end

  @doc """
  Marks the connection as established.
  """
  @spec mark_established(t()) :: t()
  def mark_established(%__MODULE__{} = state) do
    %{state | established: true}
  end

  @doc """
  Marks the connection as closed with a reason.
  """
  @spec mark_closed(t(), term()) :: t()
  def mark_closed(%__MODULE__{} = state, reason) do
    %{state | closed: true, close_reason: reason}
  end

  @doc """
  Adds a waiter to the queue (waiting for connection establishment).
  """
  @spec add_waiter(t(), :gen_statem.from()) :: t()
  def add_waiter(%__MODULE__{} = state, from) do
    %{state | waiters: [from | state.waiters]}
  end

  @doc """
  Increments packet statistics.
  """
  @spec increment_packets_sent(t(), non_neg_integer()) :: t()
  def increment_packets_sent(%__MODULE__{} = state, count \\ 1) do
    %{state | packets_sent: state.packets_sent + count}
  end

  @spec increment_packets_received(t()) :: t()
  def increment_packets_received(%__MODULE__{} = state) do
    %{state | packets_received: state.packets_received + 1}
  end

end
