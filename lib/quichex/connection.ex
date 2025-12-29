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

  This module uses a functional core pattern:
  - Pure state management in `Quichex.State`
  - Pure state transitions in `Quichex.StateMachine`
  - Side effects (UDP I/O, messages) executed via actions

  This allows for better testability and performance optimization.
  """

  @behaviour :gen_statem
  require Logger

  alias Quichex.{State, StateMachine, Action, Native}

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
    * `:active` - Active mode like `:gen_tcp` (default: `true`)
    * `:local_port` - Local port to bind to (default: `0` for random)
    * `:mode` - Workload mode: `:http`, `:webtransport`, or `:auto` (default: `:auto`)
    * `:stream_handler` - StreamHandler module for incoming streams (default: `nil`)
    * `:stream_handler_opts` - Options passed to stream handler's `init/4` (default: `[]`)
    * `:max_stream_handlers` - Maximum concurrent stream handlers (default: `1000`)

  ## Examples

      # Basic connection (imperative API)
      config = Quichex.Config.new!()
        |> Quichex.Config.set_application_protos(["http/1.1"])
        |> Quichex.Config.verify_peer(false)

      {:ok, pid} = Quichex.Connection.connect(
        host: "localhost",
        port: 4433,
        config: config
      )

      # Connection with stream handler (for incoming streams)
      {:ok, pid} = Quichex.Connection.connect(
        host: "server.example.com",
        port: 4433,
        config: config,
        stream_handler: MyApp.EchoHandler,
        stream_handler_opts: [buffer_size: 4096]
      )

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
    connect(opts)
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
  Opens a new stream and spawns a StreamHandler for it.

  ## Arguments

    * `pid` - Connection process ID
    * `opts` - Options (keyword list or atom for backward compatibility)

  ## Options

    * `:type` - Stream type: `:bidirectional` or `:unidirectional` (default: `:bidirectional`)
    * `:handler` - StreamHandler module (default: `Quichex.StreamHandler.Message`)
    * `:handler_opts` - Options passed to handler's `init/4` callback (default: `[]`)

  ## Returns

    * `{:ok, handler_pid}` - PID of the spawned StreamHandler
    * `{:error, reason}` - On failure

  ## Examples

      # Default MessageHandler (sends messages to controlling process)
      {:ok, handler} = Connection.open_stream(conn, :bidirectional)
      StreamHandler.send_data(handler, "Hello", fin: true)
      receive do
        {:quic_stream, ^handler, data} -> IO.puts(data)
      end

      # Custom handler
      {:ok, handler} = Connection.open_stream(conn,
        type: :bidirectional,
        handler: MyApp.EchoHandler,
        handler_opts: [buffer_size: 4096]
      )
  """
  @spec open_stream(pid(), :bidirectional | :unidirectional | keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def open_stream(pid, opts) when is_list(opts) do
    :gen_statem.call(pid, {:open_stream, opts})
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
    :gen_statem.call(pid, {:stream_send, stream_id, data, opts})
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
    :gen_statem.call(pid, {:stream_recv, stream_id, opts})
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
    :gen_statem.call(pid, {:stream_shutdown, stream_id, direction, error_code})
  end

  def stream_shutdown(pid, stream_id, direction, opts)
      when direction in [:read, :write, :both] and is_list(opts) do
    error_code = Keyword.get(opts, :error_code, 0)
    :gen_statem.call(pid, {:stream_shutdown, stream_id, direction, error_code})
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
      case do_init(host, port, config, opts) do
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

  ## State Functions

  # State: :init
  def init(:enter, _old_state, _data) do
    # Trigger immediate timeout to start handshake
    {:keep_state_and_data, [{:state_timeout, 0, :start_handshake}]}
  end

  def init(:state_timeout, :start_handshake, data) do
    # Use state machine to generate initial packets
    new_data = StateMachine.start_handshake(data)
    {actions, new_data} = State.take_actions(new_data)

    # Execute actions and get updated state
    updated_data = execute_actions(actions, new_data)

    # Transition to handshaking
    {:next_state, :handshaking, updated_data}
  end

  # State: :handshaking
  def handshaking(:enter, _old_state, _data) do
    # Set handshake timeout
    {:keep_state_and_data, [{:state_timeout, 10_000, :handshake_timeout}]}
  end

  def handshaking(:state_timeout, :handshake_timeout, _data) do
    Logger.error("Handshake timeout")
    {:stop, :handshake_timeout}
  end

  def handshaking(:info, {:udp, socket, _ip, _port, packet}, %State{socket: socket} = data) do
    # Process packet
    new_data = StateMachine.process_packet(data, packet)
    {actions, new_data} = State.take_actions(new_data)

    # Execute actions and get updated state
    updated_data = execute_actions(actions, new_data)

    # Check if we're now established
    if updated_data.established do
      {:next_state, :connected, updated_data}
    else
      {:keep_state, updated_data}
    end
  end

  def handshaking(:info, :quic_timeout, data) do
    # Handle timeout during handshake
    new_data = StateMachine.handle_timeout(data)
    {actions, new_data} = State.take_actions(new_data)

    # Execute actions and get updated state
    updated_data = execute_actions(actions, new_data)

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

    case Native.connection_close(data.conn_resource, true, error_code, reason_bytes) do
      {:ok, _} ->
        new_data = State.mark_closed(data, :normal)
        {:next_state, :closed, new_data, [{:reply, from, :ok}]}

      # "done" error means connection isn't ready, but we're closing anyway
      {:error, "Close error: done"} ->
        new_data = State.mark_closed(data, :normal)
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
    # Process packet with state machine
    new_data = StateMachine.process_packet(data, packet)
    {actions, new_data} = State.take_actions(new_data)

    # Execute actions and get updated state
    updated_data = execute_actions(actions, new_data)

    # Check if connection is still open
    if updated_data.closed do
      {:next_state, :closed, updated_data}
    else
      {:keep_state, updated_data}
    end
  end

  def connected(:info, :quic_timeout, data) do
    # Handle timeout
    new_data = StateMachine.handle_timeout(data)
    {actions, new_data} = State.take_actions(new_data)

    # Execute actions and get updated state
    updated_data = execute_actions(actions, new_data)

    {:keep_state, updated_data}
  end

  def connected(:info, {:stream_handler_sent, stream_id, bytes_written}, data) do
    # StreamHandler notified us that it wrote data
    # Update stream state and generate packets
    {stream, new_data} = State.get_or_create_stream(data, stream_id, :bidirectional)

    stream = Quichex.StreamState.add_bytes_sent(stream, bytes_written)

    new_data =
      new_data
      |> State.update_stream(stream)
      |> StateMachine.generate_pending_packets()

    # Execute actions (packet sends) and get updated state
    {actions, new_data} = State.take_actions(new_data)
    updated_data = execute_actions(actions, new_data)

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
    {stream_id, new_data} = StateMachine.open_stream(data, type)
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
        stream = Quichex.StreamState.add_bytes_received(stream, byte_size(stream_data))
        stream = if fin, do: Quichex.StreamState.mark_fin_received(stream), else: stream
        new_data = State.update_stream(new_data, stream)

        {:keep_state, new_data, [{:reply, from, {:ok, {stream_data, fin}}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # New API: stream_send - send data on a stream
  def connected({:call, from}, {:stream_send, stream_id, data_bytes, opts}, data) do
    fin = Keyword.get(opts, :fin, false)

    case Native.connection_stream_send(data.conn_resource, stream_id, data_bytes, fin) do
      {:ok, bytes_written} ->
        # Update stream state
        {stream, new_data} = State.get_or_create_stream(data, stream_id, :bidirectional)
        stream = Quichex.StreamState.add_bytes_sent(stream, bytes_written)
        stream = if fin, do: Quichex.StreamState.mark_fin_sent(stream), else: stream
        new_data = State.update_stream(new_data, stream)

        # Generate packets
        new_data = StateMachine.generate_pending_packets(new_data)

        # Execute actions (will send UDP packets)
        {actions, new_data} = State.take_actions(new_data)
        updated_data = execute_actions(actions, new_data)

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
    new_data = StateMachine.stream_shutdown(data, stream_id, direction, error_code)
    {actions, new_data} = State.take_actions(new_data)

    updated_data = execute_actions(actions, new_data)

    {:keep_state, updated_data, [{:reply, from, :ok}]}
  end

  def connected({:call, from}, {:close, opts}, data) do
    error_code = Keyword.get(opts, :error_code, 0)
    reason_str = Keyword.get(opts, :reason, "")
    # Ensure reason is a binary
    reason_bytes = if is_binary(reason_str), do: reason_str, else: to_string(reason_str)

    case Native.connection_close(data.conn_resource, true, error_code, reason_bytes) do
      {:ok, _} ->
        new_data = State.mark_closed(data, :normal)
        {:next_state, :closed, new_data, [{:reply, from, :ok}]}

      # "done" error means connection isn't ready, but we're closing anyway
      {:error, "Close error: done"} ->
        new_data = State.mark_closed(data, :normal)
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
    # Clean up socket
    if data.socket do
      :gen_udp.close(data.socket)
    end

    # Notify controlling process if in active mode
    if data.controlling_process do
      send(data.controlling_process, {:quic_connection_closed, self(), data.close_reason || :normal})
    end

    # Schedule stop after a short delay to allow final calls
    {:keep_state_and_data, [{:state_timeout, 1000, :stop}]}
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

  # Ignore stream handler messages in closed state
  def closed(:info, {:stream_handler_sent, _stream_id, _bytes}, _data) do
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
    if data.socket do
      :gen_udp.close(data.socket)
    end

    :ok
  end

  @impl true
  def code_change(_old_vsn, state_name, data, _extra) do
    {:ok, state_name, data}
  end

  defp do_init(host, port, config, opts) do
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

        state = %{state | controlling_process: controlling_process, scid: scid}

        {:ok, state}

      {:error, reason} ->
        :gen_udp.close(socket)
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

  defp execute_actions(actions, data) do
    context = %{
      socket: data.socket,
      conn_resource: data.conn_resource
    }

    # Reduce over actions, updating state and performing side effects
    Enum.reduce(actions, data, fn action, acc_data ->
      # All actions delegated to Action module
      Action.execute(action, context)
      acc_data
    end)
  end

end
