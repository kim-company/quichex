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

  ## Options

    * `:host` - Server hostname (required)
    * `:port` - Server port (required)
    * `:config` - `%Quichex.Config{}` struct (required)
    * `:active` - Active mode like `:gen_tcp` (default: `true`)
    * `:local_port` - Local port to bind to (default: `0` for random)
    * `:mode` - Workload mode: `:http`, `:webtransport`, or `:auto` (default: `:auto`)

  ## Examples

      config = Quichex.Config.new!()
        |> Quichex.Config.set_application_protos(["http/1.1"])
        |> Quichex.Config.verify_peer(false)

      {:ok, pid} = Quichex.Connection.connect(
        host: "localhost",
        port: 4433,
        config: config
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
  Opens a new stream.

  Returns `{:ok, stream_id}` on success.
  """
  @spec open_stream(pid(), :bidirectional | :unidirectional) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def open_stream(pid, type) when type in [:bidirectional, :unidirectional] do
    :gen_statem.call(pid, {:open_stream, type})
  end

  @doc """
  Sends data on a stream.

  ## Options

    * `:fin` - Whether to mark this as the final data on stream (default: false)

  """
  @spec stream_send(pid(), non_neg_integer(), binary(), keyword()) ::
          :ok | {:error, term()}
  def stream_send(pid, stream_id, data, opts \\ []) do
    fin = Keyword.get(opts, :fin, false)
    :gen_statem.call(pid, {:stream_send, stream_id, data, fin})
  end

  @doc """
  Receives data from a stream (passive mode).

  Returns `{:ok, data, fin?}` where `fin?` indicates if this is the last data.
  """
  @spec stream_recv(pid(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary(), boolean()} | {:error, term()}
  def stream_recv(pid, stream_id, max_len \\ 65535) do
    :gen_statem.call(pid, {:stream_recv, stream_id, max_len})
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

  @doc """
  Sets socket options (like setopts for gen_tcp).

  ## Options

    * `:active` - Active mode: `true`, `false`, `:once`, or positive integer

  """
  @spec setopts(pid(), keyword()) :: :ok | {:error, term()}
  def setopts(pid, opts) do
    :gen_statem.call(pid, {:setopts, opts})
  end

  ## gen_statem Callbacks

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init({:client, opts}) do
    Process.flag(:trap_exit, true)

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

    # Execute actions
    execute_actions(actions, new_data)

    # Transition to handshaking
    {:next_state, :handshaking, new_data}
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

    # Execute actions
    execute_actions(actions, new_data)

    # Check if we're now established
    if new_data.established do
      {:next_state, :connected, new_data}
    else
      {:keep_state, new_data}
    end
  end

  def handshaking(:info, :quic_timeout, data) do
    # Handle timeout during handshake
    new_data = StateMachine.handle_timeout(data)
    {actions, new_data} = State.take_actions(new_data)

    # Execute actions
    execute_actions(actions, new_data)

    {:keep_state, new_data}
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

  def handshaking({:call, from}, _request, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_connected}}]}
  end

  # State: :connected
  def connected(:enter, :handshaking, _data) do
    # Just entered connected state from handshaking
    Logger.info("Connection established")
    :keep_state_and_data
  end

  def connected(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def connected(:info, {:udp, socket, _ip, _port, packet}, %State{socket: socket} = data) do
    # Process packet with state machine
    new_data = StateMachine.process_packet(data, packet)
    {actions, new_data} = State.take_actions(new_data)

    # Execute actions
    execute_actions(actions, new_data)

    # Check if connection is still open
    if new_data.closed do
      {:next_state, :closed, new_data}
    else
      {:keep_state, new_data}
    end
  end

  def connected(:info, :quic_timeout, data) do
    # Handle timeout
    new_data = StateMachine.handle_timeout(data)
    {actions, new_data} = State.take_actions(new_data)

    # Execute actions
    execute_actions(actions, new_data)

    {:keep_state, new_data}
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

  def connected({:call, from}, {:open_stream, type}, data) do
    {stream_id, new_data} = StateMachine.open_stream(data, type)
    {:keep_state, new_data, [{:reply, from, {:ok, stream_id}}]}
  end

  def connected({:call, from}, {:stream_send, stream_id, data_bytes, fin}, data) do
    case StateMachine.stream_send(data, stream_id, data_bytes, fin) do
      {:ok, new_data} ->
        {actions, new_data} = State.take_actions(new_data)
        execute_actions(actions, new_data)
        {:keep_state, new_data, [{:reply, from, :ok}]}

      {:error, new_data, reason} ->
        {:keep_state, new_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def connected({:call, from}, {:stream_recv, stream_id, max_len}, data) do
    {result, new_data} = StateMachine.stream_recv(data, stream_id, max_len)
    {:keep_state, new_data, [{:reply, from, result}]}
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

    execute_actions(actions, new_data)

    {:keep_state, new_data, [{:reply, from, :ok}]}
  end

  def connected({:call, from}, {:setopts, opts}, data) do
    case Keyword.fetch(opts, :active) do
      {:ok, active} ->
        new_data = State.set_active(data, active)
        {:keep_state, new_data, [{:reply, from, :ok}]}

      :error ->
        {:keep_state_and_data, [{:reply, from, {:error, :invalid_option}}]}
    end
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

    # Resolve hostname to IP
    peer_addr = resolve_address(host, port)

    # Open UDP socket
    {:ok, socket} = :gen_udp.open(local_port, [:binary, {:active, true}])
    {:ok, {local_ip, resolved_local_port}} = :inet.sockname(socket)
    local_addr = {local_ip, resolved_local_port}

    # Generate random connection ID (16 bytes)
    scid = :crypto.strong_rand_bytes(16)

    # Get the parent process (the one that called connect/1)
    parent_pid =
      case Process.info(self(), :links) do
        {:links, [parent | _]} when is_pid(parent) ->
          parent

        _ ->
          # Fallback: try $callers
          case Process.get(:"$callers") do
            [caller | _] -> caller
            _ -> Process.group_leader()
          end
      end

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
        # Create state
        state =
          State.new(conn_resource, socket, local_addr, peer_addr, config,
            server_name: host,
            active: active,
            mode: mode
          )

        state = %{state | controlling_process: parent_pid, scid: scid}

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

    Action.execute_all(actions, context)
  end
end
