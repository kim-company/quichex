defmodule Quichex.Connection do
  @moduledoc """
  GenServer managing individual QUIC connections.

  Each connection runs in its own process for fault isolation and concurrency.
  Handles connection lifecycle, stream operations, and packet I/O.
  """

  use GenServer
  require Logger

  alias Quichex.Native

  defstruct [
    :socket,
    :conn_resource,
    :local_addr,
    :peer_addr,
    :config,
    :controlling_process,
    :active,
    :server_name,
    :scid,
    established: false,
    closed: false,
    waiters: []
  ]

  @type t :: %__MODULE__{}

  ## Client API

  @doc """
  Starts a client QUIC connection to the specified host and port.

  ## Options

    * `:host` - Server hostname (required)
    * `:port` - Server port (required)
    * `:config` - `%Quichex.Config{}` struct (required)
    * `:active` - Active mode like `:gen_tcp` (default: `true`)
    * `:local_port` - Local port to bind to (default: `0` for random)

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
  @spec connect(keyword()) :: GenServer.on_start()
  def connect(opts) do
    GenServer.start_link(__MODULE__, {:client, opts})
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
    GenServer.call(pid, :wait_connected, timeout)
  end

  @doc """
  Checks if the connection handshake is complete.
  """
  @spec is_established?(pid()) :: boolean()
  def is_established?(pid) do
    GenServer.call(pid, :is_established?)
  end

  @doc """
  Checks if the connection is closed.
  """
  @spec is_closed?(pid()) :: boolean()
  def is_closed?(pid) do
    GenServer.call(pid, :is_closed?)
  end

  @doc """
  Closes the connection gracefully.

  ## Options

    * `:error_code` - Application error code (default: 0)
    * `:reason` - Reason string (default: "")

  """
  @spec close(pid(), keyword()) :: :ok
  def close(pid, opts \\ []) do
    GenServer.call(pid, {:close, opts})
  end

  @doc """
  Gets connection information.
  """
  @spec info(pid()) :: {:ok, map()} | {:error, term()}
  def info(pid) do
    GenServer.call(pid, :info)
  end

  ## GenServer Callbacks

  @impl true
  def init({:client, opts}) do
    Process.flag(:trap_exit, true)

    # Validate required options
    with {:ok, host} <- Keyword.fetch(opts, :host),
         {:ok, port} <- Keyword.fetch(opts, :port),
         {:ok, config} <- Keyword.fetch(opts, :config) do
      do_init(host, port, config, opts)
    else
      :error ->
        # Determine which key is missing
        cond do
          not Keyword.has_key?(opts, :host) -> {:stop, {:connection_error, %KeyError{key: :host, term: opts}}}
          not Keyword.has_key?(opts, :port) -> {:stop, {:connection_error, %KeyError{key: :port, term: opts}}}
          not Keyword.has_key?(opts, :config) -> {:stop, {:connection_error, %KeyError{key: :config, term: opts}}}
        end
    end
  end

  defp do_init(host, port, config, opts) do
    active = Keyword.get(opts, :active, true)
    local_port = Keyword.get(opts, :local_port, 0)

    # Resolve hostname to IP
    peer_addr = resolve_address(host, port)

    # Open UDP socket
    {:ok, socket} = :gen_udp.open(local_port, [:binary, {:active, true}])
    {:ok, {local_ip, local_port}} = :inet.sockname(socket)
    local_addr = {local_ip, local_port}

    # Generate random connection ID (16 bytes)
    scid = :crypto.strong_rand_bytes(16)

    # Create QUIC connection
    #Convert address tuples to format Rustler can decode
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
        state = %__MODULE__{
          socket: socket,
          conn_resource: conn_resource,
          local_addr: local_addr,
          peer_addr: peer_addr,
          config: config,
          controlling_process: self(),
          active: active,
          server_name: host,
          scid: scid
        }

        # Send initial client packets
        state = send_pending_packets(state)

        # Schedule first timeout
        state = schedule_next_timeout(state)

        {:ok, state}

      {:error, reason} ->
        :gen_udp.close(socket)
        {:stop, {:connection_error, reason}}
    end
  end

  @impl true
  def handle_call(:wait_connected, _from, %{established: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:wait_connected, _from, %{closed: true} = state) do
    {:reply, {:error, :connection_closed}, state}
  end

  def handle_call(:wait_connected, from, state) do
    # Add to waiters list - will be replied to when connection is established
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:is_established?, _from, state) do
    case Native.connection_is_established(state.conn_resource) do
      {:ok, is_established} -> {:reply, is_established, %{state | established: is_established}}
      {:error, _} -> {:reply, false, state}
    end
  end

  def handle_call(:is_closed?, _from, state) do
    # Check local state first - if we called close/2, we're closed
    if state.closed do
      {:reply, true, state}
    else
      case Native.connection_is_closed(state.conn_resource) do
        {:ok, is_closed} -> {:reply, is_closed, %{state | closed: is_closed}}
        {:error, _} -> {:reply, false, state}
      end
    end
  end

  def handle_call({:close, opts}, _from, state) do
    error_code = Keyword.get(opts, :error_code, 0)
    reason = Keyword.get(opts, :reason, "") |> to_charlist()

    case Native.connection_close(state.conn_resource, true, error_code, reason) do
      {:ok, _} ->
        # Send final packets
        state = send_pending_packets(state)
        {:reply, :ok, %{state | closed: true}}

      {:error, "Close error: done"} ->
        # Connection already closed or nothing to close - treat as success
        {:reply, :ok, %{state | closed: true}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      local_address: state.local_addr,
      peer_address: state.peer_addr,
      server_name: state.server_name,
      is_established: state.established,
      is_closed: state.closed
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_info({:udp, socket, _ip, _port, packet}, %{socket: socket} = state) do
    # Build RecvInfo
    recv_info = %{
      from: state.peer_addr,
      to: state.local_addr
    }

    # Process the packet
    case Native.connection_recv(state.conn_resource, packet, recv_info) do
      {:ok, _bytes_read} ->
        # Check if connection is now established
        state =
          case Native.connection_is_established(state.conn_resource) do
            {:ok, true} ->
              if not state.established do
                # Connection just became established
                if state.active do
                  send(state.controlling_process, {:quic_connected, self()})
                end

                # Reply to all waiters
                Enum.each(state.waiters, fn from ->
                  GenServer.reply(from, :ok)
                end)

                %{state | established: true, waiters: []}
              else
                state
              end

            _ ->
              state
          end

        # Send any packets generated in response
        state = send_pending_packets(state)

        # Reschedule timeout
        state = schedule_next_timeout(state)

        {:noreply, state}

      {:error, "done"} ->
        # No more data to process (not an error)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Connection recv error: #{inspect(reason)}")
        {:stop, {:recv_error, reason}, state}
    end
  end

  def handle_info(:quic_timeout, state) do
    # Handle QUIC timeout event
    case Native.connection_on_timeout(state.conn_resource) do
      {:ok, _} ->
        # Send any packets generated by timeout handling
        state = send_pending_packets(state)

        # Schedule next timeout
        state = schedule_next_timeout(state)

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Timeout handling error: #{inspect(reason)}")
        {:stop, {:timeout_error, reason}, state}
    end
  end

  def handle_info({:EXIT, _from, reason}, state) do
    {:stop, reason, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      :gen_udp.close(state.socket)
    end

    :ok
  end

  ## Private Functions

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

  defp resolve_address(host, port) when is_tuple(host) do
    # Already an IP tuple
    {host, port}
  end

  defp send_pending_packets(state) do
    case Native.connection_send(state.conn_resource) do
      {:ok, {packet, send_info}} ->
        # Send packet via UDP
        {to_ip, to_port} = send_info.to
        :gen_udp.send(state.socket, to_ip, to_port, packet)

        # Recursively send more packets if available
        send_pending_packets(state)

      {:error, "done"} ->
        # No more packets to send
        state

      {:error, reason} ->
        Logger.warning("Failed to send packet: #{inspect(reason)}")
        state
    end
  end

  defp schedule_next_timeout(state) do
    case Native.connection_timeout(state.conn_resource) do
      {:ok, nil} ->
        # No timeout needed
        state

      {:ok, timeout_ms} ->
        # Schedule timeout
        Process.send_after(self(), :quic_timeout, timeout_ms)
        state

      {:error, _reason} ->
        # Ignore error, connection might be closed
        state
    end
  end

  defp format_address({{a, b, c, d}, port}) when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    # IPv4 address - encode as 6-byte binary: 4 bytes IP + 2 bytes port (big endian)
    <<a::8, b::8, c::8, d::8, port::16>>
  end

  defp format_address({ip_tuple, port}) when tuple_size(ip_tuple) == 8 do
    # IPv6 address - encode as 18-byte binary: 16 bytes IP + 2 bytes port
    {s0, s1, s2, s3, s4, s5, s6, s7} = ip_tuple
    <<s0::16, s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, port::16>>
  end
end
