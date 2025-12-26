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
          {:ok, pid()} | {:error, term()}
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
  Shuts down a stream in the specified direction.

  ## Arguments

    * `direction` - `:read`, `:write`, or `:both`
    * `opts` - Options
      * `:error_code` - Error code to send (default: 0)

  """
  @spec stream_shutdown(pid(), non_neg_integer(), :read | :write | :both, keyword()) ::
          :ok | {:error, term()}
  def stream_shutdown(pid, stream_id, direction, opts \\ [])
      when direction in [:read, :write, :both] do
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

    # Ensure StreamHandlerSupervisor is available (safe to lookup now - initialization complete)
    updated_data = ensure_stream_handler_sup(data)

    {:keep_state, updated_data}
  end

  def connected(:enter, _old_state, data) do
    # Ensure StreamHandlerSupervisor is available for other transitions to :connected
    updated_data = ensure_stream_handler_sup(data)
    {:keep_state, updated_data}
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
    handler = Keyword.get(opts, :handler)
    handler_opts = Keyword.get(opts, :handler_opts, [])

    {stream_id, new_data} = StateMachine.open_stream(data, type)

    # ALWAYS spawn StreamHandler (use Message handler if no handler provided)
    handler_module = handler || Quichex.StreamHandler.Message

    # For MessageHandler, inject controlling_process
    final_handler_opts =
      if handler_module == Quichex.StreamHandler.Message do
        Keyword.merge(handler_opts,
          controlling_process: new_data.controlling_process
        )
      else
        handler_opts
      end

    case spawn_stream_handler(new_data, stream_id, :outgoing, type, handler_module, final_handler_opts) do
      {:ok, handler_pid, updated_data} ->
        # Always return handler_pid
        {:keep_state, updated_data, [{:reply, from, {:ok, handler_pid}}]}

      {:error, reason} ->
        {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # Backward compatibility: handle old {:open_stream, type} format
  def connected({:call, from}, {:open_stream, type}, data) when is_atom(type) do
    connected({:call, from}, {:open_stream, [type: type]}, data)
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
    stream_handler = Keyword.get(opts, :stream_handler)
    stream_handler_opts = Keyword.get(opts, :stream_handler_opts, [])
    # Stream handler supervisor PID injected by ConnectionSupervisor
    stream_handler_sup_opt = Keyword.get(opts, :__stream_handler_sup__)

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
           config.resource
         ) do
      {:ok, conn_resource} ->
        # Get StreamHandlerSupervisor PID (from opts, or lookup lazily when needed)
        # Don't look up during init to avoid deadlock with parent supervisor
        stream_handler_sup = stream_handler_sup_opt

        # Create state
        state =
          State.new(conn_resource, socket, local_addr, peer_addr, config,
            server_name: host,
            active: active,
            mode: mode,
            stream_handler: stream_handler,
            stream_handler_opts: stream_handler_opts,
            stream_handler_sup: stream_handler_sup
          )

        state = %{state | controlling_process: controlling_process, scid: scid}

        {:ok, state}

      {:error, reason} ->
        :gen_udp.close(socket)
        {:error, reason}
    end
  end

  # Ensure stream_handler_sup is available (lookup if needed)
  defp ensure_stream_handler_sup(data) do
    if data.stream_handler_sup do
      data
    else
      sup_pid = get_stream_handler_supervisor()
      %{data | stream_handler_sup: sup_pid}
    end
  end

  defp get_stream_handler_supervisor do
    # Get our parent supervisor (ConnectionSupervisor) from ancestors
    case Process.get(:"$ancestors") do
      [parent | _] when is_pid(parent) ->
        # Look up StreamHandlerSupervisor from parent's children
        # Retry a few times to handle supervisor initialization race condition
        get_stream_handler_supervisor_retry(parent, 10)

      _ ->
        raise "Connection must be started under supervision (no parent found in ancestors)"
    end
  end

  defp get_stream_handler_supervisor_retry(_parent, 0) do
    raise "StreamHandlerSupervisor not found after retries - Connection must be started under ConnectionSupervisor"
  end

  defp get_stream_handler_supervisor_retry(parent, retries_left) do
    case Quichex.ConnectionSupervisor.stream_handler_supervisor_pid(parent) do
      {:ok, sup_pid} ->
        sup_pid

      {:error, :not_found} ->
        # Supervisor might still be initializing, wait a bit and retry
        Process.sleep(50)
        get_stream_handler_supervisor_retry(parent, retries_left - 1)
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
      case action do
        {:spawn_stream_handler, stream_id, direction, stream_type, initial_data, initial_fin} ->
          # ALWAYS spawn handler (use MessageHandler if no user handler configured)
          if acc_data.stream_handler_sup do
            handler_module = acc_data.stream_handler || Quichex.StreamHandler.Message

            # For MessageHandler, inject controlling_process
            final_handler_opts =
              if handler_module == Quichex.StreamHandler.Message do
                Keyword.merge(acc_data.stream_handler_opts || [],
                  controlling_process: acc_data.controlling_process
                )
              else
                acc_data.stream_handler_opts || []
              end

            handler_init_opts = [
              conn_resource: acc_data.conn_resource,
              conn_pid: self(),
              stream_id: stream_id,
              direction: direction,
              stream_type: stream_type,
              handler_module: handler_module,
              handler_opts: final_handler_opts
            ]

            case DynamicSupervisor.start_child(
                   acc_data.stream_handler_sup,
                   {Quichex.StreamHandler, handler_init_opts}
                 ) do
              {:ok, handler_pid} ->
                # Send initial data to handler immediately
                GenServer.cast(handler_pid, {:stream_data, initial_data, initial_fin})

                # Update state IMMEDIATELY - no message passing!
                put_in(acc_data.stream_handlers[stream_id], handler_pid)

              {:error, reason} ->
                Logger.warning(
                  "Failed to spawn incoming stream handler for stream #{stream_id}: #{inspect(reason)}"
                )

                acc_data
            end
          else
            acc_data
          end

        {:route_to_handler, handler_pid, data_bytes, fin} ->
          # Send data to handler process
          GenServer.cast(handler_pid, {:stream_data, data_bytes, fin})
          acc_data

        _ ->
          # Delegate other actions to Action module
          Action.execute(action, context)
          acc_data
      end
    end)
  end

  defp spawn_stream_handler(state, stream_id, direction, stream_type, handler_module, handler_opts) do
    if state.stream_handler_sup do
      handler_init_opts = [
        conn_resource: state.conn_resource,
        conn_pid: self(),
        stream_id: stream_id,
        direction: direction,
        stream_type: stream_type,
        handler_module: handler_module,
        handler_opts: handler_opts
      ]

      case DynamicSupervisor.start_child(
             state.stream_handler_sup,
             {Quichex.StreamHandler, handler_init_opts}
           ) do
        {:ok, handler_pid} ->
          Logger.debug(
            "Spawned StreamHandler for stream #{stream_id}: direction=#{direction}, type=#{stream_type}, module=#{inspect(handler_module)}"
          )

          updated_state = %{
            state
            | stream_handlers: Map.put(state.stream_handlers, stream_id, handler_pid)
          }

          {:ok, handler_pid, updated_state}

        {:error, reason} ->
          Logger.error("Failed to spawn StreamHandler for stream #{stream_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.warning(
        "Cannot spawn StreamHandler: StreamHandlerSupervisor not initialized"
      )

      {:error, :no_supervisor}
    end
  end
end
