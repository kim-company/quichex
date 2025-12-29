defmodule Quichex.State do
  @moduledoc """
  Pure functional QUIC connection state.

  This module defines the complete state for a QUIC connection, including:
  - Connection resource (NIF reference to quiche connection)
  - Network addresses (local and peer)
  - Stream states
  - Pending actions to be executed

  All state transformations are pure functions. The state machine operates
  on this struct and returns `{new_state, actions}` tuples.

  ## Socket Mode

  The UDP socket is always in `{active, true}` mode for minimum latency.
  Data is immediately delivered to StreamHandler callbacks - no buffering.
  """

  alias Quichex.{StreamState, Action}

  @type workload_mode :: :http | :webtransport | :auto

  @type t :: %__MODULE__{
          # Core connection state
          conn_resource: reference() | nil,
          local_addr: {tuple(), :inet.port_number()} | nil,
          peer_addr: {tuple(), :inet.port_number()} | nil,
          config: Quichex.Config.t() | nil,
          socket: :gen_udp.socket() | nil,
          scid: binary() | nil,
          server_name: String.t() | nil,

          # Process management
          controlling_process: pid() | nil,
          waiters: [:gen_statem.from()],

          # Connection lifecycle
          established: boolean(),
          closed: boolean(),
          close_reason: term() | nil,

          # Stream management
          next_bidi_stream: non_neg_integer(),
          next_uni_stream: non_neg_integer(),
          streams: %{StreamState.stream_id() => StreamState.t()},
          readable_streams: [StreamState.stream_id()],

          # Actions queue
          pending_actions: [Action.t()],

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
            local_addr: nil,
            peer_addr: nil,
            config: nil,
            socket: nil,
            scid: nil,
            server_name: nil,
            controlling_process: nil,
            waiters: [],
            established: false,
            closed: false,
            close_reason: nil,
            next_bidi_stream: 0,
            next_uni_stream: 0,
            streams: %{},
            readable_streams: [],
            pending_actions: [],
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
    * `:stream_worker_threshold` - Bytes threshold for spawning stream workers (default: 65536)
    * `:max_stream_workers` - Maximum concurrent stream workers (default: 100)
    * `:stream_handler` - Module implementing Quichex.StreamHandler.Behaviour for incoming streams (default: `nil`)
    * `:stream_handler_opts` - Options passed to stream handler init (default: `[]`)
    * `:stream_handler_sup` - PID of StreamHandlerSupervisor (default: `nil`)

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
  Adds an action to the pending actions queue.
  """
  @spec add_action(t(), Action.t()) :: t()
  def add_action(%__MODULE__{} = state, action) do
    %{state | pending_actions: [action | state.pending_actions]}
  end

  @doc """
  Adds multiple actions to the pending actions queue.
  """
  @spec add_actions(t(), [Action.t()]) :: t()
  def add_actions(%__MODULE__{} = state, actions) when is_list(actions) do
    %{state | pending_actions: actions ++ state.pending_actions}
  end

  @doc """
  Clears and returns the pending actions.

  Returns a tuple of `{actions, updated_state}` where actions are in execution order
  (reversed from the queue which is built with prepending).
  """
  @spec take_actions(t()) :: {[Action.t()], t()}
  def take_actions(%__MODULE__{pending_actions: actions} = state) do
    {Enum.reverse(actions), %{state | pending_actions: []}}
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
  """
  @spec allocate_bidi_stream(t()) :: {StreamState.stream_id(), t()}
  def allocate_bidi_stream(%__MODULE__{next_bidi_stream: next} = state) do
    stream_id = next * 4
    {stream_id, %{state | next_bidi_stream: next + 1}}
  end

  @doc """
  Allocates a new unidirectional stream ID.
  """
  @spec allocate_uni_stream(t()) :: {StreamState.stream_id(), t()}
  def allocate_uni_stream(%__MODULE__{next_uni_stream: next} = state) do
    stream_id = next * 4 + 2
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
  Replies to all waiters and clears the waiter list.

  Generates reply actions for all waiters.
  """
  @spec reply_to_waiters(t(), term()) :: t()
  def reply_to_waiters(%__MODULE__{waiters: []} = state, _response), do: state

  def reply_to_waiters(%__MODULE__{waiters: waiters} = state, response) do
    actions = Enum.map(waiters, fn from -> {:reply, from, response} end)
    state = %{state | waiters: []}
    add_actions(state, actions)
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
