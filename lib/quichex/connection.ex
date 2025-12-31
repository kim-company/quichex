defmodule Quichex.Connection do
  @moduledoc """
  State machine managing individual QUIC connections using :gen_statem.

  Each connection runs in its own process for fault isolation and concurrency.
  Handles connection lifecycle, stream operations, and packet I/O.

  ## States

  - `:init` - Initial state, setting up UDP socket and connection
  - `:handshaking` - Performing TLS/QUIC handshake
  - `:connected` - Connection established, can send/receive streams
  - `:connected_read_only` - Server closing, can only receive
  - `:closed` - Connection closed

  ## Architecture

  This module implements a simplified gen_statem with inline state transitions:
  - Pure state management in `Quichex.State`
  - State transitions and side effects handled inline in state callbacks
  - Handler actions executed immediately

  This provides a clear, direct data flow with minimal indirection.
  """

  @behaviour :gen_statem
  require Logger

  alias Quichex.{State, StreamState, Native}

  @doc """
  Returns a child specification for starting Connection under a supervisor.

  This function is required for using Connection with ExUnit's
  `start_link_supervised!/1` and with Elixir supervisors.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  ## Public API

  @doc """
  Starts a client QUIC connection to the specified host and port.

  > #### Deprecation Notice {: .warning}
  >
  > This function starts a connection without supervision. For production use,
  > prefer `Quichex.start_connection/1` which provides proper supervision and
  > automatic resource cleanup.

  ## Options

    * `:host` - Server hostname (required)
    * `:port` - Server port (required)
    * `:config` - `%Quichex.Config{}` struct (required)
    * `:local_port` - Local port to bind to (default: `0` for random)
    * `:mode` - Workload mode: `:http`, `:webtransport`, or `:auto` (default: `:auto`)
    * `:stream_recv_buffer_size` - Maximum bytes to read per stream_recv call (default: `65536`)

  ## Examples

      config = Quichex.Config.new!()
        |> Quichex.Config.set_application_protos(["http/1.1"])
        |> Quichex.Config.verify_peer(false)

      {:ok, conn} = Quichex.Connection.connect(
        host: "localhost",
        port: 4433,
        config: config
      )

      # Wait for connection to establish
      receive do
        {:quic_connected, ^conn} -> :ok
      end

  """
  @spec connect(keyword()) :: :gen_statem.start_ret()
  def connect(opts) do
    :gen_statem.start_link(__MODULE__, {:client, opts}, [])
  end

  @doc """
  Starts a connection and links it to the caller, with additional start options.
  """
  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts) do
    mode = Keyword.get(opts, :mode, :client)

    case mode do
      :server ->
        :gen_statem.start_link(__MODULE__, {:server, opts}, [])

      :client ->
        :gen_statem.start_link(__MODULE__, {:client, opts}, [])
    end
  end

  @doc """
  Waits for the connection to be established (handshake complete).

  Returns `:ok` when established or `{:error, reason}` on timeout/failure.

  ## Options

    * `:timeout` - Maximum time to wait in milliseconds (default: 5000)

  """
  @spec wait_connected(pid(), keyword()) :: :ok | {:error, term()}
  def wait_connected(pid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    :gen_statem.call(pid, :wait_connected, timeout)
  end

  @doc """
  Checks if the connection handshake is complete.
  """
  @spec is_established?(pid()) :: boolean()
  def is_established?(pid) do
    :gen_statem.call(pid, :is_established?)
  end

  @doc """
  Checks if the connection is closed.
  """
  @spec is_closed?(pid()) :: boolean()
  def is_closed?(pid) do
    :gen_statem.call(pid, :is_closed?)
  end

  @doc """
  Closes the connection gracefully.

  ## Options

    * `:error_code` - Application error code (default: 0)
    * `:reason` - Reason string (default: "")

  """
  @spec close(pid(), keyword()) :: :ok
  def close(pid, opts \\ []) do
    :gen_statem.call(pid, {:close, opts})
  end

  @doc """
  Gets connection information.
  """
  @spec info(pid()) :: {:ok, map()} | {:error, term()}
  def info(pid) do
    :gen_statem.call(pid, :info)
  end

  @doc """
  Opens a new stream.

  ## Arguments

    * `pid` - Connection process ID
    * `opts` - Options (keyword list or atom for backward compatibility)

  ## Options

    * `:type` - Stream type: `:bidirectional` or `:unidirectional` (default: `:bidirectional`)

  ## Returns

    * `{:ok, stream_id}` - Stream ID of the newly opened stream
    * `{:error, reason}` - On failure

  ## Examples

      # Open a bidirectional stream
      {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)
      {:ok, _bytes} = Connection.stream_send(conn, stream_id, "Hello", fin: true)

      # Wait for readable notification
      receive do
        {:quic_stream_readable, ^conn, ^stream_id} ->
          {:ok, {_data, _fin}} = Connection.stream_recv(conn, stream_id)
      end

      # Shorthand for type
      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
  """
  @spec open_stream(pid(), :bidirectional | :unidirectional | keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def open_stream(pid, opts) when is_list(opts) do
    type = Keyword.get(opts, :type, :bidirectional)

    metadata = %{
      conn_pid: pid,
      type: type
    }

    start_time = Quichex.Telemetry.start([:stream, :open], metadata)

    case :gen_statem.call(pid, {:open_stream, opts}) do
      {:ok, stream_id} = result ->
        Quichex.Telemetry.stop(
          [:stream, :open],
          start_time,
          Map.put(metadata, :stream_id, stream_id)
        )

        result

      {:error, reason} = error ->
        Quichex.Telemetry.exception(
          [:stream, :open],
          start_time,
          :error,
          reason,
          [],
          metadata
        )

        error
    end
  end

  def open_stream(pid, type) when type in [:bidirectional, :unidirectional] do
    open_stream(pid, type: type)
  end

  @doc """
  Gets list of streams that have data to read.
  """
  @spec readable_streams(pid()) :: {:ok, [non_neg_integer()]} | {:error, term()}
  def readable_streams(pid) do
    :gen_statem.call(pid, :readable_streams)
  end

  @doc """
  Gets list of streams that can be written to.
  """
  @spec writable_streams(pid()) :: {:ok, [non_neg_integer()]} | {:error, term()}
  def writable_streams(pid) do
    :gen_statem.call(pid, :writable_streams)
  end

  @doc """
  Sends data on a stream.

  ## Arguments

    * `pid` - Connection process
    * `stream_id` - Stream ID to send data on
    * `data` - Binary data to send
    * `opts` - Options
      * `:fin` - Set FIN flag to close write side (default: false)

  ## Returns

    * `{:ok, bytes_written}` - Number of bytes written
    * `{:error, reason}` - Error reason

  ## Examples

      {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)
      {:ok, 5} = Connection.stream_send(conn, stream_id, "Hello", fin: false)
      {:ok, 6} = Connection.stream_send(conn, stream_id, " World", fin: true)

  """
  @spec stream_send(pid(), non_neg_integer(), binary(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def stream_send(pid, stream_id, data, opts \\ []) when is_binary(data) do
    fin = Keyword.get(opts, :fin, false)
    data_size = byte_size(data)

    metadata = %{
      conn_pid: pid,
      stream_id: stream_id,
      fin: fin,
      data_size: data_size
    }

    start_time = Quichex.Telemetry.start([:stream, :send], metadata, %{data_size: data_size})

    case :gen_statem.call(pid, {:stream_send, stream_id, data, opts}) do
      {:ok, bytes_written} = result ->
        Quichex.Telemetry.stop(
          [:stream, :send],
          start_time,
          Map.put(metadata, :partial, bytes_written < data_size),
          %{bytes_written: bytes_written, data_size: data_size}
        )

        result

      {:error, reason} = error ->
        Quichex.Telemetry.exception(
          [:stream, :send],
          start_time,
          :error,
          reason,
          [],
          metadata
        )

        error
    end
  end

  @doc """
  Receives data from a readable stream.

  Call this in response to `{:quic_stream_readable, conn_pid, stream_id}` messages.

  ## Arguments

    * `pid` - Connection process
    * `stream_id` - Stream ID to read from
    * `opts` - Options
      * `:max_bytes` - Maximum bytes to read (default: connection's configured buffer size)

  ## Returns

    * `{:ok, {data, fin}}` - Data binary and FIN flag
    * `{:error, :done}` - Stream not currently readable
    * `{:error, reason}` - Other error

  ## Examples

      receive do
        {:quic_stream_readable, ^conn, stream_id} ->
          {:ok, {data, fin}} = Connection.stream_recv(conn, stream_id, max_bytes: 4096)
          IO.puts("Received: \#{data}, FIN: \#{fin}")
      end

  """
  @spec stream_recv(pid(), non_neg_integer(), keyword()) ::
          {:ok, {binary(), boolean()}} | {:error, term()}
  def stream_recv(pid, stream_id, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, 65535)

    metadata = %{
      conn_pid: pid,
      stream_id: stream_id,
      max_bytes: max_bytes
    }

    start_time = Quichex.Telemetry.start([:stream, :recv], metadata)

    case :gen_statem.call(pid, {:stream_recv, stream_id, opts}) do
      {:ok, {data, fin}} = result ->
        Quichex.Telemetry.stop(
          [:stream, :recv],
          start_time,
          Map.put(metadata, :fin, fin),
          %{bytes_read: byte_size(data)}
        )

        result

      {:error, reason} = error ->
        Quichex.Telemetry.exception(
          [:stream, :recv],
          start_time,
          :error,
          reason,
          [],
          metadata
        )

        error
    end
  end

  @doc """
  Shuts down a stream in the specified direction.

  ## Arguments

    * `direction` - `:read`, `:write`, or `:both`
    * `error_code_or_opts` - Error code (integer) or keyword options
      * When integer: Error code to send
      * When keyword list: `:error_code` - Error code to send (default: 0)

  ## Examples

      # With error code directly
      :ok = Connection.stream_shutdown(conn, stream_id, :write, 0)

      # With keyword opts
      :ok = Connection.stream_shutdown(conn, stream_id, :write, error_code: 42)

  """
  @spec stream_shutdown(pid(), non_neg_integer(), :read | :write | :both, non_neg_integer() | keyword()) ::
          :ok | {:error, term()}
  def stream_shutdown(pid, stream_id, direction, error_code_or_opts \\ 0)

  def stream_shutdown(pid, stream_id, direction, error_code)
      when direction in [:read, :write, :both] and is_integer(error_code) do
    metadata = %{
      conn_pid: pid,
      stream_id: stream_id,
      direction: direction,
      error_code: error_code
    }

    start_time = Quichex.Telemetry.start([:stream, :shutdown], metadata)

    case :gen_statem.call(pid, {:stream_shutdown, stream_id, direction, error_code}) do
      :ok = result ->
        Quichex.Telemetry.stop([:stream, :shutdown], start_time, metadata)
        result

      {:error, reason} = error ->
        Quichex.Telemetry.exception(
          [:stream, :shutdown],
          start_time,
          :error,
          reason,
          [],
          metadata
        )

        error
    end
  end

  def stream_shutdown(pid, stream_id, direction, opts)
      when direction in [:read, :write, :both] and is_list(opts) do
    error_code = Keyword.get(opts, :error_code, 0)
    stream_shutdown(pid, stream_id, direction, error_code)
  end

  ## gen_statem Callbacks

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init({:client, opts}) do
    # Validate required options
    with {:ok, host} <- Keyword.fetch(opts, :host),
         {:ok, port} <- Keyword.fetch(opts, :port),
         {:ok, config} <- Keyword.fetch(opts, :config) do
      case do_init_client(host, port, config, opts) do
        {:ok, data} ->
          {:ok, :init, data}

        {:error, reason} ->
          {:stop, {:connection_error, reason}}
      end
    else
      :error ->
        # Determine which key is missing
        cond do
          not Keyword.has_key?(opts, :host) ->
            {:stop, {:connection_error, %KeyError{key: :host, term: opts}}}

          not Keyword.has_key?(opts, :port) ->
            {:stop, {:connection_error, %KeyError{key: :port, term: opts}}}

          not Keyword.has_key?(opts, :config) ->
            {:stop, {:connection_error, %KeyError{key: :config, term: opts}}}
        end
    end
  end

  def init({:server, opts}) do
    # Validate required server options
    required = [:config, :socket, :local_addr, :peer_addr, :scid, :dcid, :listener_pid, :handler]

    case validate_required_opts(opts, required) do
      :ok ->
        case do_init_server(opts) do
          {:ok, data} ->
            {:ok, :init, data}

          {:error, reason} ->
            {:stop, {:connection_error, reason}}
        end

      {:error, missing_key} ->
        {:stop, {:connection_error, %KeyError{key: missing_key, term: opts}}}
    end
  end

  ## State Functions

  # State: :init
  def init(:enter, _old_state, %State{connection_mode: :client}) do
    # Client: Trigger immediate timeout to start handshake
    {:keep_state_and_data, [{:state_timeout, 0, :start_handshake}]}
  end

  def init(:enter, _old_state, %State{connection_mode: :server}) do
    # Server: Wait for first packet from client (no immediate action)
    :keep_state_and_data
  end

  def init(:state_timeout, :start_handshake, %State{connection_mode: :client} = data) do
    # Emit handshake start event
    metadata = %{
      conn_pid: self(),
      mode: :client,
      peer_addr: data.peer_addr,
      local_addr: data.local_addr
    }

    start_time = Quichex.Telemetry.start([:connection, :handshake], metadata)

    # Client: Generate and send initial packets, schedule timeout
    updated_data =
      data
      |> Map.put(:handshake_start_time, start_time)
      |> generate_and_send_packets()
      |> schedule_next_timeout()

    # Transition to handshaking
    {:next_state, :handshaking, updated_data}
  end

  # Server: Process first packet and transition to handshaking
  def init(:info, {:udp, socket, _ip, _port, packet}, %State{socket: socket, connection_mode: :server} = data) do
    recv_info = %{from: data.peer_addr, to: data.local_addr}

    # Emit handshake start event
    metadata = %{
      conn_pid: self(),
      mode: :server,
      peer_addr: data.peer_addr,
      local_addr: data.local_addr
    }

    start_time = Quichex.Telemetry.start([:connection, :handshake], metadata)

    case Native.connection_recv(data.conn_resource, packet, recv_info) do
      {:ok, _bytes_read} ->
        # Process first packet and send response
        updated_data =
          data
          |> Map.put(:handshake_start_time, start_time)
          |> State.increment_packets_received()
          |> generate_and_send_packets()
          |> schedule_next_timeout()

        # Transition to handshaking
        {:next_state, :handshaking, updated_data}

      {:error, reason} ->
        Logger.error("Server init packet failed: #{inspect(reason)}")
        {:stop, {:init_failed, reason}}
    end
  end

  # State: :handshaking
  def handshaking(:enter, _old_state, _data) do
    # Set handshake timeout
    {:keep_state_and_data, [{:state_timeout, 10_000, :handshake_timeout}]}
  end

  def handshaking(:state_timeout, :handshake_timeout, data) do
    Logger.error("Handshake timeout")

    # Emit handshake exception event
    if data.handshake_start_time do
      metadata = %{
        conn_pid: self(),
        mode: data.connection_mode,
        peer_addr: data.peer_addr,
        local_addr: data.local_addr
      }

      Quichex.Telemetry.exception(
        [:connection, :handshake],
        data.handshake_start_time,
        :error,
        :timeout,
        [],
        metadata
      )
    end

    {:stop, :handshake_timeout}
  end

  def handshaking(:info, {:udp, socket, _ip, _port, packet}, %State{socket: socket} = data) do
    # Process packet inline
    recv_info = %{from: data.peer_addr, to: data.local_addr}

    updated_data = case Native.connection_recv(data.conn_resource, packet, recv_info) do
      {:ok, _bytes_read} ->
        data
        |> State.increment_packets_received()
        |> check_if_established()
        |> check_if_peer_closed()
        |> process_all_readable_streams()
        |> process_writable_streams()
        |> generate_and_send_packets()

      {:error, "done"} ->
        data

      {:error, reason} ->
        Logger.error("Packet processing error: #{inspect(reason)}")
        State.mark_closed(data, {:recv_error, reason})
    end

    # Detect connection established event
    updated_data =
      if updated_data.established and not data.established do
        call_handler(:handle_connected, [self()], updated_data)
      else
        updated_data
      end

    # Check if we're now established
    if updated_data.established do
      {:next_state, :connected, updated_data}
    else
      {:keep_state, updated_data}
    end
  end

  def handshaking(:info, :quic_timeout, data) do
    # Handle timeout during handshake
    updated_data = case Native.connection_on_timeout(data.conn_resource) do
      {:ok, _} ->
        data
        |> generate_and_send_packets()
        |> process_all_readable_streams()
        |> process_writable_streams()
        |> schedule_next_timeout()

      {:error, reason} ->
        Logger.error("Timeout handling error: #{inspect(reason)}")
        State.mark_closed(data, {:timeout_error, reason})
    end

    {:keep_state, updated_data}
  end

  def handshaking({:call, from}, :wait_connected, data) do
    # Add to waiters list (will be replied to when established)
    new_data = State.add_waiter(data, from)
    {:keep_state, new_data}
  end

  def handshaking({:call, from}, :is_established?, _data) do
    {:keep_state_and_data, [{:reply, from, false}]}
  end

  def handshaking({:call, from}, :is_closed?, _data) do
    {:keep_state_and_data, [{:reply, from, false}]}
  end

  def handshaking({:call, from}, :info, data) do
    info_map = %{
      server_name: data.server_name,
      is_established: data.established,
      is_closed: data.closed,
      local_address: data.local_addr,
      peer_address: data.peer_addr,
      packets_sent: data.packets_sent,
      packets_received: data.packets_received,
      bytes_sent: data.bytes_sent,
      bytes_received: data.bytes_received,
      active_streams: map_size(data.streams)
    }
    {:keep_state_and_data, [{:reply, from, {:ok, info_map}}]}
  end

  def handshaking({:call, from}, {:close, opts}, data) do
    error_code = Keyword.get(opts, :error_code, 0)
    reason_str = Keyword.get(opts, :reason, "")
    reason_bytes = if is_binary(reason_str), do: reason_str, else: to_string(reason_str)

    # Emit close start event
    metadata = %{
      conn_pid: self(),
      error_code: error_code,
      reason: reason_str
    }

    start_time = Quichex.Telemetry.start([:connection, :close], metadata)

    case Native.connection_close(data.conn_resource, true, error_code, reason_bytes) do
      {:ok, _} ->
        # Generate and send close packets before transitioning
        new_data =
          data
          |> Map.put(:operation_timers, Map.put(data.operation_timers, :close, start_time))
          |> State.mark_closed(:normal)
          |> generate_and_send_packets()

        {:next_state, :closed, new_data, [{:reply, from, :ok}]}

      # "done" error means connection isn't ready, but we're closing anyway
      {:error, "Close error: done"} ->
        new_data =
          data
          |> Map.put(:operation_timers, Map.put(data.operation_timers, :close, start_time))
          |> State.mark_closed(:normal)

        {:next_state, :closed, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # Ignore unexpected info messages during handshake
  def handshaking(:info, _msg, _data) do
    :keep_state_and_data
  end

  def handshaking({:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_connected}}]}
  end

  # State: :connected
  def connected(:enter, :handshaking, data) do
    # Just entered connected state from handshaking
    Logger.info("Connection established")
    {:keep_state, data}
  end

  def connected(:enter, _old_state, data) do
    {:keep_state, data}
  end

  def connected(:info, {:udp, socket, _ip, _port, packet}, %State{socket: socket} = data) do
    # Process packet inline
    recv_info = %{from: data.peer_addr, to: data.local_addr}

    updated_data = case Native.connection_recv(data.conn_resource, packet, recv_info) do
      {:ok, _bytes_read} ->
        data
        |> State.increment_packets_received()
        |> check_if_established()
        |> check_if_peer_closed()
        |> process_readable_streams()
        |> process_writable_streams()
        |> generate_and_send_packets()

      {:error, "done"} ->
        data

      {:error, reason} ->
        Logger.error("Packet processing error: #{inspect(reason)}")
        State.mark_closed(data, {:recv_error, reason})
    end

    # Detect new streams (stream_opened events)
    old_stream_ids = MapSet.new(Map.keys(data.streams))
    new_stream_ids = MapSet.new(Map.keys(updated_data.streams))
    newly_opened_streams = MapSet.difference(new_stream_ids, old_stream_ids)

    updated_data =
      Enum.reduce(newly_opened_streams, updated_data, fn stream_id, acc ->
        # Determine direction based on stream ID (odd = peer-initiated)
        direction = if rem(stream_id, 2) == 1, do: :incoming, else: :outgoing
        # TODO: detect uni vs bidi streams properly
        stream_type = :bidirectional

        call_handler(:handle_stream_opened, [self(), stream_id, direction, stream_type], acc)
      end)

    # Detect readable streams (stream_readable events)
    # Process readable streams repeatedly until all data is drained
    updated_data = process_all_readable_streams(updated_data)

    # Process writable streams to continue any partial sends
    # This handles large data transfers that exceeded flow control window
    updated_data = process_writable_streams(updated_data)

    # Check if connection is still open
    if updated_data.closed do
      {:next_state, :closed, updated_data}
    else
      {:keep_state, updated_data}
    end
  end

  def connected(:info, :quic_timeout, data) do
    # Handle timeout inline
    updated_data = case Native.connection_on_timeout(data.conn_resource) do
      {:ok, _} ->
        data
        |> generate_and_send_packets()
        |> process_all_readable_streams()
        |> process_writable_streams()
        |> schedule_next_timeout()

      {:error, reason} ->
        Logger.error("Timeout handling error: #{inspect(reason)}")
        State.mark_closed(data, {:timeout_error, reason})
    end

    {:keep_state, updated_data}
  end

  def connected({:call, from}, :wait_connected, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def connected({:call, from}, :is_established?, _data) do
    {:keep_state_and_data, [{:reply, from, true}]}
  end

  def connected({:call, from}, :is_closed?, _data) do
    {:keep_state_and_data, [{:reply, from, false}]}
  end

  def connected({:call, from}, {:open_stream, opts}, data) when is_list(opts) do
    type = Keyword.get(opts, :type, :bidirectional)
    {stream_id, new_data} = do_open_stream(data, type)
    {:keep_state, new_data, [{:reply, from, {:ok, stream_id}}]}
  end

  # Backward compatibility: handle old {:open_stream, type} format
  def connected({:call, from}, {:open_stream, type}, data) when is_atom(type) do
    connected({:call, from}, {:open_stream, [type: type]}, data)
  end

  # New API: stream_recv - read data from a readable stream
  def connected({:call, from}, {:stream_recv, stream_id, opts}, data) do
    max_bytes = Keyword.get(opts, :max_bytes, data.stream_recv_buffer_size)

    case Native.connection_stream_recv(data.conn_resource, stream_id, max_bytes) do
      {:ok, {stream_data, fin}} ->
        # Update stream state
        {stream, new_data} = State.get_or_create_stream(data, stream_id, :bidirectional)
        stream = StreamState.add_bytes_received(stream, byte_size(stream_data))
        stream = if fin, do: StreamState.mark_fin_received(stream), else: stream
        new_data = State.update_stream(new_data, stream)

        {:keep_state, new_data, [{:reply, from, {:ok, {stream_data, fin}}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # New API: stream_send - send data on a stream
  def connected({:call, from}, {:stream_send, stream_id, data_bytes, opts}, data) do
    fin = Keyword.get(opts, :fin, false)
    data_size = byte_size(data_bytes)

    case Native.connection_stream_send(data.conn_resource, stream_id, data_bytes, fin) do
      {:ok, bytes_written} ->
        # Update stream state
        {stream, new_data} = State.get_or_create_stream(data, stream_id, :bidirectional)
        stream = StreamState.add_bytes_sent(stream, bytes_written)

        # Only mark FIN as sent if we wrote ALL the data
        # Per QUIC spec and quiche behavior: FIN is only sent with the last byte
        stream = if fin and bytes_written == data_size do
          StreamState.mark_fin_sent(stream)
        else
          stream
        end

        new_data = State.update_stream(new_data, stream)

        # If partial write, store remaining data for later
        new_data = if bytes_written < data_size do
          remaining = binary_part(data_bytes, bytes_written, data_size - bytes_written)
          %{new_data | partial_sends: Map.put(new_data.partial_sends, stream_id, {remaining, fin})}
        else
          new_data
        end

        # Generate and send packets inline
        updated_data = generate_and_send_packets(new_data)

        {:keep_state, updated_data, [{:reply, from, {:ok, bytes_written}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def connected({:call, from}, :readable_streams, data) do
    {:keep_state_and_data, [{:reply, from, {:ok, data.readable_streams}}]}
  end

  def connected({:call, from}, :writable_streams, data) do
    case Native.connection_writable_streams(data.conn_resource) do
      {:ok, streams} -> {:keep_state_and_data, [{:reply, from, {:ok, streams}}]}
      {:error, reason} -> {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def connected({:call, from}, {:stream_shutdown, stream_id, direction, error_code}, data) do
    updated_data = do_stream_shutdown(data, stream_id, direction, error_code)
    {:keep_state, updated_data, [{:reply, from, :ok}]}
  end

  def connected({:call, from}, {:close, opts}, data) do
    error_code = Keyword.get(opts, :error_code, 0)
    reason_str = Keyword.get(opts, :reason, "")
    # Ensure reason is a binary
    reason_bytes = if is_binary(reason_str), do: reason_str, else: to_string(reason_str)

    # Emit close start event
    metadata = %{
      conn_pid: self(),
      error_code: error_code,
      reason: reason_str
    }

    start_time = Quichex.Telemetry.start([:connection, :close], metadata)

    case Native.connection_close(data.conn_resource, true, error_code, reason_bytes) do
      {:ok, _} ->
        # Generate and send close packets before transitioning
        new_data =
          data
          |> Map.put(:operation_timers, Map.put(data.operation_timers, :close, start_time))
          |> State.mark_closed(:normal)
          |> generate_and_send_packets()

        {:next_state, :closed, new_data, [{:reply, from, :ok}]}

      # "done" error means connection isn't ready, but we're closing anyway
      {:error, "Close error: done"} ->
        new_data =
          data
          |> Map.put(:operation_timers, Map.put(data.operation_timers, :close, start_time))
          |> State.mark_closed(:normal)

        {:next_state, :closed, new_data, [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def connected({:call, from}, :info, data) do
    info_map = %{
      server_name: data.server_name,
      is_established: data.established,
      is_closed: data.closed,
      local_address: data.local_addr,
      peer_address: data.peer_addr,
      packets_sent: data.packets_sent,
      packets_received: data.packets_received,
      bytes_sent: data.bytes_sent,
      bytes_received: data.bytes_received,
      active_streams: map_size(data.streams)
    }

    {:keep_state_and_data, [{:reply, from, {:ok, info_map}}]}
  end

  # State: :closed
  def closed(:enter, _old_state, data) do
    # Emit close stop event with final statistics
    if close_start_time = Map.get(data.operation_timers, :close) do
      metadata = %{
        conn_pid: self(),
        close_reason: data.close_reason || :normal,
        active_streams: map_size(data.streams)
      }

      measurements = %{
        packets_sent: data.packets_sent,
        packets_received: data.packets_received,
        bytes_sent: data.bytes_sent,
        bytes_received: data.bytes_received
      }

      Quichex.Telemetry.stop(
        [:connection, :close],
        close_start_time,
        metadata,
        measurements
      )
    end

    # Clean up socket (only if we own it - client mode)
    cleanup_socket(data)

    # Call handler callback for connection closed
    updated_data = call_handler(:handle_connection_closed, [self(), data.close_reason || :normal], data)

    # Schedule stop after a short delay to allow final calls
    {:keep_state, updated_data, [{:state_timeout, 50, :stop}]}
  end

  def closed(:state_timeout, :stop, _data) do
    {:stop, :normal}
  end

  # Ignore timeout messages in closed state
  def closed(:info, :quic_timeout, _data) do
    :keep_state_and_data
  end

  # Ignore UDP packets in closed state
  def closed(:info, {:udp, _socket, _ip, _port, _packet}, _data) do
    :keep_state_and_data
  end

  def closed({:call, from}, :is_closed?, _data) do
    {:keep_state_and_data, [{:reply, from, true}]}
  end

  def closed({:call, from}, :is_established?, _data) do
    {:keep_state_and_data, [{:reply, from, false}]}
  end

  def closed({:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :closed}}]}
  end

  ## Helper Functions

  @impl true
  def terminate(_reason, _state_name, data) do
    # Clean up socket (only if we own it - client mode)
    cleanup_socket(data)
    :ok
  end

  @impl true
  def code_change(_old_vsn, state_name, data, _extra) do
    {:ok, state_name, data}
  end

  # Validates that all required options are present
  defp validate_required_opts(opts, required_keys) do
    case Enum.find(required_keys, fn key -> not Keyword.has_key?(opts, key) end) do
      nil -> :ok
      missing_key -> {:error, missing_key}
    end
  end

  # Initialize client connection
  defp do_init_client(host, port, config, opts) do
    active = Keyword.get(opts, :active, true)
    local_port = Keyword.get(opts, :local_port, 0)
    mode = Keyword.get(opts, :mode, :auto)
    stream_recv_buffer_size = Keyword.get(opts, :stream_recv_buffer_size, 16384)

    # Get controlling process (injected by ConnectionRegistry for supervised connections)
    controlling_process =
      case Keyword.get(opts, :controlling_process) do
        pid when is_pid(pid) ->
          # Use explicit controlling_process from opts (supervised mode)
          pid

        nil ->
          # Fallback for unsupervised connections (backward compatibility)
          case Process.info(self(), :links) do
            {:links, [parent | _]} when is_pid(parent) ->
              parent

            _ ->
              case Process.get(:"$callers") do
                [caller | _] -> caller
                _ -> Process.group_leader()
              end
          end
      end

    # Resolve hostname to IP
    peer_addr = resolve_address(host, port)

    # Open UDP socket
    {:ok, socket} = :gen_udp.open(local_port, [:binary, {:active, true}])
    {:ok, {local_ip, resolved_local_port}} = :inet.sockname(socket)
    local_addr = {local_ip, resolved_local_port}

    # Generate random connection ID (16 bytes)
    scid = :crypto.strong_rand_bytes(16)

    # Create QUIC connection
    local_addr_arg = format_address(local_addr)
    peer_addr_arg = format_address(peer_addr)

    case Native.connection_new_client(
           scid,
           host,
           local_addr_arg,
           peer_addr_arg,
           config.resource,
           stream_recv_buffer_size
         ) do
      {:ok, conn_resource} ->
        # Create state
        state =
          State.new(conn_resource, socket, local_addr, peer_addr, config,
            server_name: host,
            active: active,
            mode: mode,
            stream_recv_buffer_size: stream_recv_buffer_size
          )

        state = %{state |
          connection_mode: :client,
          controlling_process: controlling_process,
          scid: scid
        }

        # Initialize handler
        handler_module = Keyword.get(opts, :handler, Quichex.Handler.Default)
        handler_opts = Keyword.get(opts, :handler_opts, [controlling_process: controlling_process])

        case handler_module.init(self(), handler_opts) do
          {:ok, handler_state} ->
            state = %{state | handler_module: handler_module, handler_state: handler_state}
            {:ok, state}

          {:error, reason} ->
            :gen_udp.close(socket)
            {:error, {:handler_init_failed, reason}}
        end

      {:error, reason} ->
        :gen_udp.close(socket)
        {:error, reason}
    end
  end

  # Initialize server connection
  defp do_init_server(opts) do
    config = Keyword.fetch!(opts, :config)
    socket = Keyword.fetch!(opts, :socket)
    local_addr = Keyword.fetch!(opts, :local_addr)
    peer_addr = Keyword.fetch!(opts, :peer_addr)
    scid = Keyword.fetch!(opts, :scid)
    dcid = Keyword.fetch!(opts, :dcid)
    listener_pid = Keyword.fetch!(opts, :listener_pid)
    handler = Keyword.fetch!(opts, :handler)

    mode = Keyword.get(opts, :mode, :auto)
    stream_recv_buffer_size = Keyword.get(opts, :stream_recv_buffer_size, 16384)
    handler_opts = Keyword.get(opts, :handler_opts, [])

    # Create server connection using quiche::accept
    local_addr_arg = format_address(local_addr)
    peer_addr_arg = format_address(peer_addr)

    case Native.connection_new_server(
           scid,
           nil,  # odcid only used for stateless retry (not yet implemented)
           local_addr_arg,
           peer_addr_arg,
           config.resource,
           stream_recv_buffer_size
         ) do
      {:ok, conn_resource} ->
        # Create state
        state =
          State.new(conn_resource, socket, local_addr, peer_addr, config,
            mode: mode,
            stream_recv_buffer_size: stream_recv_buffer_size
          )

        state = %{state |
          connection_mode: :server,
          scid: scid,
          dcid: dcid,
          listener_pid: listener_pid,
          controlling_process: nil  # Server has no controlling process
        }

        # Initialize handler (REQUIRED for server)
        case handler.init(self(), handler_opts) do
          {:ok, handler_state} ->
            state = %{state | handler_module: handler, handler_state: handler_state}
            {:ok, state}

          {:error, reason} ->
            # Don't close socket (listener owns it)
            {:error, {:handler_init_failed, reason}}
        end

      {:error, reason} ->
        # Don't close socket (listener owns it)
        {:error, reason}
    end
  end

  defp resolve_address(host, port) when is_binary(host) do
    # Try to parse as IP address first
    case :inet.parse_address(to_charlist(host)) do
      {:ok, ip} ->
        {ip, port}

      {:error, _} ->
        # Resolve hostname
        case :inet.gethostbyname(to_charlist(host)) do
          {:ok, {:hostent, _name, _aliases, :inet, _length, [ip | _]}} ->
            {ip, port}

          {:error, reason} ->
            raise "Failed to resolve host #{host}: #{inspect(reason)}"
        end
    end
  end

  # Cleans up socket - only closes if we own it (client mode)
  defp cleanup_socket(%State{socket: nil}), do: :ok

  defp cleanup_socket(%State{socket: socket, connection_mode: :client}) do
    # Client mode: we own the socket, close it
    :gen_udp.close(socket)
  end

  defp cleanup_socket(%State{connection_mode: :server}) do
    # Server mode: listener owns the socket, don't close it
    :ok
  end

  defp format_address({{a, b, c, d}, port})
       when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    # IPv4 address - encode as 6-byte binary: 4 bytes IP + 2 bytes port (big endian)
    <<a::8, b::8, c::8, d::8, port::16>>
  end

  defp format_address({ip_tuple, port}) when tuple_size(ip_tuple) == 8 do
    # IPv6 address - encode as 18-byte binary: 16 bytes IP + 2 bytes port
    {s0, s1, s2, s3, s4, s5, s6, s7} = ip_tuple

    <<s0::16, s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, port::16>>
  end

  # Handler callback helper
  defp call_handler(_callback_name, _args, %{handler_module: nil} = data) do
    # No handler configured, just return data unchanged
    data
  end

  defp call_handler(callback_name, args, data) do
    try do
      case apply(data.handler_module, callback_name, args ++ [data.handler_state]) do
        {:ok, new_handler_state} ->
          %{data | handler_state: new_handler_state}

        {:ok, new_handler_state, actions} when is_list(actions) ->
          data = %{data | handler_state: new_handler_state}
          execute_handler_actions(actions, data)

        other ->
          Logger.warning(
            "Handler callback #{callback_name} returned unexpected value: #{inspect(other)}"
          )

          data
      end
    rescue
      e ->
        Logger.error("Handler callback #{callback_name} crashed: #{inspect(e)}")
        reraise e, __STACKTRACE__
    end
  end

  # Execute handler actions immediately
  defp execute_handler_actions(actions, state) when is_list(actions) do
    Enum.reduce(actions, state, &execute_handler_action/2)
  end

  defp execute_handler_action({:send_data, stream_id, data, opts}, state) do
    fin = Keyword.get(opts, :fin, false)

    case do_stream_send(state, stream_id, data, fin) do
      {:ok, new_state} -> new_state
      {:error, reason} ->
        Logger.debug("Handler action send_data failed: #{inspect(reason)}")
        state
    end
  end

  defp execute_handler_action({:read_stream, stream_id, opts}, state) do
    max_bytes = Keyword.get(opts, :max_bytes, state.stream_recv_buffer_size)
    # Drain the stream completely, following the quiche example pattern
    drain_stream_completely(state, stream_id, max_bytes)
  end

  defp execute_handler_action({:refuse_stream, stream_id, error_code}, state) do
    do_stream_shutdown(state, stream_id, :both, error_code)
  end

  defp execute_handler_action({:open_stream, opts}, state) do
    type = Keyword.get(opts, :type, :bidirectional)
    {_stream_id, new_state} = do_open_stream(state, type)
    new_state
  end

  defp execute_handler_action({:close_connection, error_code, reason}, state) do
    case Native.connection_close(state.conn_resource, true, error_code, reason) do
      {:ok, _} -> State.mark_closed(state, :normal)
      _ -> state
    end
  end

  defp execute_handler_action({:shutdown_stream, stream_id, direction, error_code}, state) do
    do_stream_shutdown(state, stream_id, direction, error_code)
  end

  defp execute_handler_action(unknown, state) do
    Logger.warning("Unknown handler action: #{inspect(unknown)}")
    state
  end

  # Drain a stream completely by reading in a loop until Done
  # This follows the pattern from quiche/examples/server.rs:
  #   while let Ok((read, fin)) = conn.stream_recv(s, &mut buf) { ... }
  defp drain_stream_completely(state, stream_id, max_bytes) do
    case Native.connection_stream_recv(state.conn_resource, stream_id, max_bytes) do
      {:ok, {stream_data, fin}} ->
        # Update stream state
        {stream, new_state} = State.get_or_create_stream(state, stream_id, :bidirectional)
        stream = StreamState.add_bytes_received(stream, byte_size(stream_data))
        stream = if fin, do: StreamState.mark_fin_received(stream), else: stream
        new_state = State.update_stream(new_state, stream)

        # Call handler with the data (if callback is implemented)
        new_state = if state.handler_module && function_exported?(state.handler_module, :handle_stream_data, 5) do
          call_handler(:handle_stream_data, [self(), stream_id, stream_data, fin], new_state)
        else
          new_state
        end

        # Keep reading until Done (tail-recursive)
        drain_stream_completely(new_state, stream_id, max_bytes)

      {:error, _reason} ->
        # Done - quiche has no more data buffered for this stream
        state
    end
  end

  # Helper functions merged from StateMachine

  defp do_open_stream(%State{} = state, :bidirectional) do
    {stream_id, state} = State.allocate_bidi_stream(state)
    {stream, state} = State.get_or_create_stream(state, stream_id, :bidirectional)
    {stream_id, State.update_stream(state, stream)}
  end

  defp do_open_stream(%State{} = state, :unidirectional) do
    {stream_id, state} = State.allocate_uni_stream(state)
    {stream, state} = State.get_or_create_stream(state, stream_id, :unidirectional)
    {stream_id, State.update_stream(state, stream)}
  end

  defp do_stream_send(%State{} = state, stream_id, data, fin) when is_binary(data) do
    # Check if there's already a send in progress on this stream
    case Map.get(state.partial_sends, stream_id) do
      nil ->
        # No partial send - try to send immediately
        do_stream_send_loop(state, stream_id, data, 0, fin)

      {pending_data, _pending_fin} ->
        # Partial send in progress - enqueue this send request
        # It will be processed when the stream becomes writable and current send completes
        Logger.debug("Stream #{stream_id}: Enqueueing #{byte_size(data)} bytes (#{byte_size(pending_data)} bytes pending)")
        queue = Map.get(state.send_queues, stream_id, :queue.new())
        new_queue = :queue.in({data, fin}, queue)
        new_state = %{state | send_queues: Map.put(state.send_queues, stream_id, new_queue)}
        {:ok, new_state}
    end
  end

  defp do_stream_send_loop(state, _stream_id, data, offset, _fin) when offset >= byte_size(data) do
    # All data sent
    {:ok, state}
  end

  defp do_stream_send_loop(state, stream_id, data, offset, fin) do
    remaining = binary_part(data, offset, byte_size(data) - offset)
    # Only send FIN with the last chunk
    send_fin = fin and (offset + byte_size(remaining) == byte_size(data))

    case Native.connection_stream_send(state.conn_resource, stream_id, remaining, send_fin) do
      {:ok, bytes_written} when bytes_written > 0 ->
        # Update stream state
        {stream, new_state} = State.get_or_create_stream(state, stream_id, :bidirectional)
        stream = StreamState.add_bytes_sent(stream, bytes_written)
        stream = if send_fin and bytes_written == byte_size(remaining), do: StreamState.mark_fin_sent(stream), else: stream
        new_state = State.update_stream(new_state, stream)

        # Generate and send packets after each write
        new_state = generate_and_send_packets(new_state)

        # Continue with remaining data (tail-recursive loop)
        do_stream_send_loop(new_state, stream_id, data, offset + bytes_written, fin)

      {:ok, 0} ->
        # Flow control exhausted - store partial send for later
        # When stream becomes writable, we'll continue sending
        new_state = %{state | partial_sends: Map.put(state.partial_sends, stream_id, {remaining, fin})}
        {:ok, new_state}

      {:error, reason} ->
        # Real error (not just flow control)
        {:error, reason}
    end
  end

  defp do_stream_shutdown(%State{} = state, stream_id, direction, error_code)
       when direction in [:read, :write, :both] do
    direction_str =
      case direction do
        :read -> "read"
        :write -> "write"
        :both -> "both"
      end

    case Native.connection_stream_shutdown(state.conn_resource, stream_id, direction_str, error_code) do
      {:ok, _} ->
        generate_and_send_packets(state)

      {:error, reason} ->
        Logger.warning("Stream shutdown error on stream #{stream_id}: #{inspect(reason)}")
        state
    end
  end

  defp check_if_established(%State{established: true} = state), do: state

  defp check_if_established(%State{established: false} = state) do
    case Native.connection_is_established(state.conn_resource) do
      {:ok, true} ->
        Logger.debug("Connection established")

        # Emit handshake stop event
        if state.handshake_start_time do
          metadata = %{
            conn_pid: self(),
            mode: state.connection_mode,
            peer_addr: state.peer_addr,
            local_addr: state.local_addr
          }

          Quichex.Telemetry.stop(
            [:connection, :handshake],
            state.handshake_start_time,
            metadata
          )
        end

        state = State.mark_established(state)
        state = %{state | handshake_start_time: nil}
        reply_to_waiters(state, :ok)

      _ ->
        state
    end
  end

  # Check if peer has closed the connection or if we're draining
  defp check_if_peer_closed(%State{closed: true} = state), do: state

  defp check_if_peer_closed(%State{closed: false} = state) do
    # Check if connection is closed
    closed? = case Native.connection_is_closed(state.conn_resource) do
      {:ok, true} -> true
      _ -> false
    end

    # Check if connection is draining (received CONNECTION_CLOSE from peer)
    draining? = case Native.connection_is_draining(state.conn_resource) do
      {:ok, true} -> true
      _ -> false
    end

    cond do
      closed? ->
        Logger.debug("Connection is closed")
        State.mark_closed(state, :peer_closed)

      draining? ->
        Logger.debug("Entering draining state (received CONNECTION_CLOSE from peer)")
        # Per RFC 9000: enter draining state, stop sending packets
        # The draining period is 3× PTO, managed by quiche
        State.mark_closed(state, :draining)

      true ->
        state
    end
  end

  defp process_readable_streams(%State{} = state) do
    case Native.connection_readable_streams(state.conn_resource) do
      {:ok, readable_streams} ->
        state = %{state | readable_streams: readable_streams}

        # Update state with new streams if any
        Enum.reduce(readable_streams, state, fn stream_id, acc ->
          if not Map.has_key?(acc.streams, stream_id) do
            {_stream, new_state} = State.get_or_create_stream(acc, stream_id, :bidirectional)
            new_state
          else
            acc
          end
        end)

      {:error, _reason} ->
        state
    end
  end

  # Process all readable streams repeatedly until fully drained
  # This ensures large data transfers are completely read even if they
  # exceed the stream_recv_buffer_size
  defp process_all_readable_streams(state, max_iterations \\ 100) do
    # First populate readable_streams list
    state = process_readable_streams(state)
    # Then drain them
    process_all_readable_streams_loop(state, 0, max_iterations)
  end

  defp process_all_readable_streams_loop(state, iteration, max_iterations) when iteration >= max_iterations do
    Logger.warning("Max iterations (#{max_iterations}) reached while processing readable streams")
    state
  end

  defp process_all_readable_streams_loop(state, iteration, max_iterations) do
    # Call handler for each currently readable stream
    updated_state =
      Enum.reduce(state.readable_streams, state, fn stream_id, acc ->
        call_handler(:handle_stream_readable, [self(), stream_id], acc)
      end)

    # Check if there are still readable streams after processing
    case Native.connection_readable_streams(updated_state.conn_resource) do
      {:ok, readable_streams} when readable_streams != [] ->
        # Update state with new readable_streams and continue processing
        updated_state = %{updated_state | readable_streams: readable_streams}
        process_all_readable_streams_loop(updated_state, iteration + 1, max_iterations)

      _ ->
        # No more readable streams - done
        %{updated_state | readable_streams: []}
    end
  end

  # Process writable streams to continue partial sends
  # This implements the pattern from quiche/examples/server.rs:498-529
  defp process_writable_streams(state) do
    case Native.connection_writable_streams(state.conn_resource) do
      {:ok, writable_streams} ->
        # For each writable stream, check if we have a partial send to complete
        Enum.reduce(writable_streams, state, fn stream_id, acc ->
          case Map.get(acc.partial_sends, stream_id) do
            {remaining_data, fin} ->
              # Continue sending the remaining data
              case do_stream_send_loop(acc, stream_id, remaining_data, 0, fin) do
                {:ok, new_state} ->
                  # Check if partial send was cleared (fully sent)
                  if Map.has_key?(new_state.partial_sends, stream_id) do
                    # Still partial - don't process queue yet
                    new_state
                  else
                    # Fully sent - process queue
                    process_send_queue(new_state, stream_id)
                  end

                {:error, _reason} ->
                  # Keep partial send on error
                  acc
              end

            nil ->
              # No partial send - check if there are queued sends to start
              process_send_queue(acc, stream_id)
          end
        end)

      {:error, _reason} ->
        state
    end
  end

  # Process queued sends for a stream
  defp process_send_queue(state, stream_id) do
    # Only process queue if no partial send is in progress
    case Map.get(state.partial_sends, stream_id) do
      nil ->
        # No partial send - check if there's a queued send
        queue = Map.get(state.send_queues, stream_id, :queue.new())

        case :queue.out(queue) do
          {{:value, {data, fin}}, new_queue} ->
            # Dequeue and try to send
            queue_remaining = :queue.len(new_queue)
            Logger.debug("Stream #{stream_id}: Dequeuing #{byte_size(data)} bytes (#{queue_remaining} items remain), fin=#{fin}")
            new_state = %{state | send_queues: Map.put(state.send_queues, stream_id, new_queue)}

            case do_stream_send_loop(new_state, stream_id, data, 0, fin) do
              {:ok, final_state} ->
                # Send completed (or became partial) - recursively check queue again
                if Map.has_key?(final_state.partial_sends, stream_id) do
                  Logger.debug("Stream #{stream_id}: Send became partial (#{queue_remaining} items still queued)")
                end
                process_send_queue(final_state, stream_id)

              {:error, reason} ->
                Logger.warning("Stream #{stream_id}: Send error: #{inspect(reason)}")
                # Error - stop processing queue
                new_state
            end

          {:empty, _queue} ->
            # No queued sends - clean up empty queue
            %{state | send_queues: Map.delete(state.send_queues, stream_id)}
        end

      {pending_data, _pending_fin} ->
        # Partial send still in progress - don't process queue yet
        queue_size = Map.get(state.send_queues, stream_id, :queue.new()) |> :queue.len()
        if queue_size > 0 do
          Logger.debug("Stream #{stream_id}: Skipping queue (#{queue_size} items) - partial send of #{byte_size(pending_data)} bytes in progress")
        end
        state
    end
  end

  defp generate_and_send_packets(state) do
    packets = collect_packets_recursive(state.conn_resource, [])

    unless packets == [] do
      send_udp_packets(state.socket, packets)
    end

    State.increment_packets_sent(state, length(packets))
  end

  defp collect_packets_recursive(conn_resource, acc) do
    case Native.connection_send(conn_resource) do
      {:ok, {packet, send_info}} ->
        collect_packets_recursive(conn_resource, [{packet, send_info} | acc])

      {:error, "done"} ->
        Enum.reverse(acc)

      {:error, _} ->
        []
    end
  end

  defp send_udp_packets(_socket, []), do: :ok

  defp send_udp_packets(socket, packets) do
    Enum.each(packets, fn {packet, send_info} ->
      {to_ip, to_port} = send_info.to
      :gen_udp.send(socket, to_ip, to_port, packet)
    end)
  end

  defp schedule_next_timeout(state) do
    # Cancel previous timeout if it exists
    if state.timeout_ref do
      Process.cancel_timer(state.timeout_ref)
    end

    case Native.connection_timeout(state.conn_resource) do
      {:ok, timeout_ms} when is_integer(timeout_ms) ->
        ref = Process.send_after(self(), :quic_timeout, timeout_ms)
        %{state | timeout_ref: ref}

      _ ->
        %{state | timeout_ref: nil}
    end
  end

  defp reply_to_waiters(%State{waiters: []} = state, _response), do: state

  defp reply_to_waiters(%State{waiters: waiters} = state, response) do
    Enum.each(waiters, fn from ->
      :gen_statem.reply(from, response)
    end)

    %{state | waiters: []}
  end

end
