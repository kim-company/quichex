defmodule Quichex.Listener do
  @moduledoc """
  GenServer managing a QUIC listener that accepts incoming connections.

  The Listener owns a UDP socket and routes incoming packets to the appropriate
  connection processes based on the Destination Connection ID (DCID).

  ## Handler Requirement

  Unlike client connections, **server connections REQUIRE a custom handler**.
  There is no "controlling process" for incoming connections, so you must
  provide a handler module to process connection and stream events.

  ## Usage

      defmodule MyApp.ServerHandler do
        @behaviour Quichex.Handler

        def init(_conn_pid, opts) do
          {:ok, %{requests: 0}}
        end

        def handle_connected(conn_pid, state) do
          IO.puts("New client connected!")
          {:ok, state}
        end

        def handle_stream_readable(conn_pid, stream_id, state) do
          # Read the stream data
          actions = [{:read_stream, stream_id, []}]
          {:ok, state, actions}
        end

        def handle_stream_data(conn_pid, stream_id, data, fin, state) do
          # Echo the data back
          actions = [{:send_data, stream_id, data, fin: fin}]
          {:ok, %{state | requests: state.requests + 1}, actions}
        end

        # ... implement other callbacks
      end

      # Start listener
      config = Quichex.Config.new!()
        |> Quichex.Config.load_cert_chain_from_pem_file("cert.pem")
        |> Quichex.Config.load_priv_key_from_pem_file("key.pem")
        |> Quichex.Config.set_application_protos(["h3"])

      {:ok, listener} = Quichex.Listener.start_link(
        port: 4433,
        config: config,
        handler: MyApp.ServerHandler,
        handler_opts: []  # Optional
      )

  ## Options

    * `:port` - Port to listen on (required)
    * `:config` - `%Quichex.Config{}` with server certificates (required)
    * `:handler` - Handler module implementing `Quichex.Handler` behaviour (required)
    * `:handler_opts` - Options passed to handler init/2 (optional, default: [])
    * `:name` - Optional registered name for the listener process

  ## Packet Routing

  When a packet arrives:
  1. Parse header with `Quichex.Native.header_info()` to extract DCID
  2. Look up DCID in routing table
  3. If found: forward packet to existing connection
  4. If not found: accept new connection and add to routing table

  ## Connection Lifecycle

  - New connection: Listener spawns supervised Connection via ConnectionRegistry
  - Listener monitors each connection process
  - On connection termination: Remove from routing table automatically
  """

  use GenServer
  require Logger

  alias Quichex.{Native, ConnectionRegistry}

  @typedoc "Listener state"
  @type t :: %__MODULE__{
          socket: :gen_udp.socket(),
          port: :inet.port_number(),
          config: Quichex.Config.t(),
          handler: module(),
          handler_opts: keyword(),
          connections: %{binary() => pid()},
          monitors: %{reference() => binary()}
        }

  defstruct [
    :socket,
    :port,
    :config,
    :handler,
    :handler_opts,
    connections: %{},
    monitors: %{}
  ]

  ## Public API

  @doc """
  Starts a QUIC listener on the specified port.

  ## Options

    * `:port` - Port to listen on (required)
    * `:config` - `%Quichex.Config{}` with server certificates (required)
    * `:handler` - Handler module for connections (required)
    * `:handler_opts` - Options for handler (optional, default: [])
    * `:name` - Optional registered name

  ## Examples

      {:ok, listener} = Quichex.Listener.start_link(
        port: 4433,
        config: server_config,
        handler: MyApp.ServerHandler
      )

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts, [])
    end
  end

  @doc """
  Returns the number of active connections.
  """
  @spec connection_count(GenServer.server()) :: non_neg_integer()
  def connection_count(listener) do
    GenServer.call(listener, :connection_count)
  end

  @doc """
  Returns the local socket address.
  """
  @spec local_address(GenServer.server()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | {:error, term()}
  def local_address(listener) do
    GenServer.call(listener, :local_address)
  end

  @doc """
  Stops the listener and closes all connections.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(listener) do
    GenServer.stop(listener)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    # Validate required options
    with {:ok, port} <- Keyword.fetch(opts, :port),
         {:ok, config} <- Keyword.fetch(opts, :config),
         {:ok, handler} <- Keyword.fetch(opts, :handler) do
      # Handler must be a module implementing Quichex.Handler
      case Code.ensure_compiled(handler) do
        {:module, ^handler} ->
          unless function_exported?(handler, :init, 2) do
            {:stop, {:invalid_handler, "Handler must implement Quichex.Handler behaviour"}}
          else
            do_init(port, config, handler, opts)
          end

        {:error, reason} ->
          {:stop, {:invalid_handler, "Handler module not found: #{inspect(reason)}"}}
      end
    else
      :error ->
        missing =
          [:port, :config, :handler]
          |> Enum.find(fn key -> not Keyword.has_key?(opts, key) end)

        {:stop, {:missing_required_option, missing}}
    end
  end

  defp do_init(port, config, handler, opts) do
    handler_opts = Keyword.get(opts, :handler_opts, [])

    # Open UDP socket in active mode
    socket_opts = [:binary, {:active, true}, {:reuseaddr, true}]

    case :gen_udp.open(port, socket_opts) do
      {:ok, socket} ->
        {:ok, actual_port} = :inet.port(socket)
        Logger.info("QUIC Listener started on port #{actual_port}")

        state = %__MODULE__{
          socket: socket,
          port: actual_port,
          config: config,
          handler: handler,
          handler_opts: handler_opts
        }

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to open UDP socket: #{inspect(reason)}")
        {:stop, {:socket_error, reason}}
    end
  end

  @impl true
  def handle_info({:udp, socket, peer_ip, peer_port, packet}, %{socket: socket} = state) do
    # Route packet to appropriate connection
    case route_packet(packet, {peer_ip, peer_port}, state) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.debug("Packet routing failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Connection process died - remove from routing table
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      dcid ->
        Logger.debug("Connection terminated, DCID: #{Base.encode16(dcid)}")

        new_state = %{
          state
          | connections: Map.delete(state.connections, dcid),
            monitors: Map.delete(state.monitors, ref)
        }

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:connection_count, _from, state) do
    {:reply, map_size(state.connections), state}
  end

  @impl true
  def handle_call(:local_address, _from, state) do
    case :inet.sockname(state.socket) do
      {:ok, address} -> {:reply, {:ok, address}, state}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Close all active connections gracefully
    for {_dcid, conn_pid} <- state.connections do
      if Process.alive?(conn_pid) do
        Quichex.Connection.close(conn_pid, error_code: 0, reason: "Listener shutting down")
      end
    end

    # Don't close the socket here - let server connections send their final CONNECTION_CLOSE frames
    # The socket will be garbage collected when all processes holding references to it are done
    # This allows server connections to properly notify clients before shutting down

    :ok
  end

  ## Private Helpers

  # Routes a packet to the appropriate connection or accepts a new connection
  defp route_packet(packet, peer_addr, state) do
    # Parse header to extract DCID for routing
    case Native.header_info(packet, 16) do
      {:ok, %{dcid: dcid}} ->
        case Map.get(state.connections, dcid) do
          nil ->
            # New connection - accept it
            accept_connection(packet, peer_addr, dcid, state)

          conn_pid ->
            # Existing connection - forward packet
            forward_packet(conn_pid, packet, peer_addr, state)
        end

      {:error, reason} ->
        # Invalid packet - ignore
        Logger.debug("Invalid packet from #{inspect(peer_addr)}: #{reason}")
        {:ok, state}
    end
  end

  # Forwards a packet to an existing connection
  defp forward_packet(conn_pid, packet, {peer_ip, peer_port}, state) do
    # Send packet to connection process as if it came from :gen_udp
    send(conn_pid, {:udp, state.socket, peer_ip, peer_port, packet})
    {:ok, state}
  end

  # Accepts a new connection
  defp accept_connection(packet, peer_addr, dcid, state) do
    {peer_ip, peer_port} = peer_addr

    # Get local socket address
    {:ok, {local_ip, local_port}} = :inet.sockname(state.socket)

    # If peer is localhost and we're bound to 0.0.0.0, use 127.0.0.1 as local address
    # This matches the actual packet destination address for loopback connections
    local_ip = case {local_ip, peer_ip} do
      {{0, 0, 0, 0}, {127, 0, 0, 1}} -> {127, 0, 0, 1}
      _ -> local_ip
    end

    local_addr = {local_ip, local_port}

    # Generate server connection ID (SCID)
    scid = :crypto.strong_rand_bytes(16)
    # Convert to list to match dcid type from header_info
    scid_list = :binary.bin_to_list(scid)

    Logger.info("Accepting new connection from #{format_addr(peer_addr)}, DCID: #{:binary.list_to_bin(dcid) |> Base.encode16()}")

    # Start new server connection
    server_opts = [
      mode: :server,
      config: state.config,
      socket: state.socket,
      local_addr: local_addr,
      peer_addr: peer_addr,
      scid: scid,
      dcid: dcid,
      listener_pid: self(),
      handler: state.handler,
      handler_opts: state.handler_opts
    ]

    case ConnectionRegistry.start_connection(server_opts) do
      {:ok, conn_pid} ->
        # Monitor the connection
        ref = Process.monitor(conn_pid)

        # Add to routing table using server's SCID (not client's DCID!)
        # The client will use our SCID as the DCID in subsequent packets
        new_state = %{
          state
          | connections: Map.put(state.connections, scid_list, conn_pid),
            monitors: Map.put(state.monitors, ref, scid_list)
        }

        # Forward the initial packet to the new connection
        send(conn_pid, {:udp, state.socket, peer_ip, peer_port, packet})

        Logger.debug("Connection accepted, PID: #{inspect(conn_pid)}")
        {:ok, new_state}

      {:error, reason} ->
        Logger.error("Failed to accept connection: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Formats address for logging
  defp format_addr({ip, port}) do
    "#{:inet.ntoa(ip)}:#{port}"
  end
end
