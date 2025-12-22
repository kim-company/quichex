# Socket debugging test
# This test adds extensive logging to see socket message flow
#
# Start server first:
#   cd ../quiche && RUST_LOG=trace target/debug/quiche-server \
#     --cert ../quichex/priv/cert.crt --key ../quichex/priv/cert.key \
#     --listen 127.0.0.1:4433 --no-retry

require Logger

# Temporarily patch Connection module to add logging
defmodule Quichex.Connection.Debug do
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
    waiters: [],
    next_bidi_stream: 0,
    next_uni_stream: 0,
    streams: %{},
    udp_message_count: 0
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    config = Keyword.fetch!(opts, :config)
    local_port = Keyword.get(opts, :local_port, 0)

    # Resolve hostname to IP
    peer_addr = resolve_address(host, port)

    # Open UDP socket with active mode
    Logger.info("Opening UDP socket on port #{local_port}...")
    {:ok, socket} = :gen_udp.open(local_port, [:binary, {:active, true}])
    {:ok, {local_ip, local_port}} = :inet.sockname(socket)
    local_addr = {local_ip, local_port}

    Logger.info("Socket opened: #{inspect(socket)}, local_addr=#{inspect(local_addr)}")
    Logger.info("Socket owner: #{inspect(Process.info(self(), :registered_name))}")

    # Check socket options
    {:ok, socket_opts} = :inet.getopts(socket, [:active, :mode, :buffer])
    Logger.info("Socket options: #{inspect(socket_opts)}")

    # Generate random connection ID
    scid = :crypto.strong_rand_bytes(16)

    # Create QUIC connection
    local_addr_arg = format_address(local_addr)
    peer_addr_arg = format_address(peer_addr)

    case Native.connection_new_client(scid, host, local_addr_arg, peer_addr_arg, config.resource) do
      {:ok, conn_resource} ->
        Logger.info("QUIC connection created successfully")

        state = %__MODULE__{
          socket: socket,
          conn_resource: conn_resource,
          local_addr: local_addr,
          peer_addr: peer_addr,
          config: config,
          controlling_process: self(),
          active: true,
          server_name: host,
          scid: scid
        }

        # Send initial client packets
        Logger.info("Sending initial packets...")
        case send_pending_packets(state) do
          {:ok, state} ->
            Logger.info("Initial packets sent successfully")
            {:ok, state}

          {:error, reason} ->
            Logger.warning("Initial send error (may be ok): #{inspect(reason)}")
            {:ok, state}
        end

      {:error, reason} ->
        :gen_udp.close(socket)
        {:stop, {:connection_error, reason}}
    end
  end

  @impl true
  def handle_call(:is_established?, _from, state) do
    {:reply, state.established, state}
  end

  def handle_call({:open_stream, :bidirectional}, _from, state) do
    id = state.next_bidi_stream * 4
    {:reply, {:ok, id}, %{state | next_bidi_stream: state.next_bidi_stream + 1}}
  end

  def handle_call({:stream_send, stream_id, data, fin}, _from, state) do
    case Native.connection_stream_send(state.conn_resource, stream_id, data, fin) do
      {:ok, _} ->
        case send_pending_packets(state) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:readable_streams, _from, state) do
    case Native.connection_readable_streams(state.conn_resource) do
      {:ok, streams} -> {:reply, {:ok, streams}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stream_recv, stream_id, max_len}, _from, state) do
    case Native.connection_stream_recv(state.conn_resource, stream_id, max_len) do
      {:ok, {data, fin}} -> {:reply, {:ok, data, fin}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:udp, socket, from_ip, from_port, packet}, %{socket: socket} = state) do
    state = %{state | udp_message_count: state.udp_message_count + 1}

    Logger.info("=== UDP MESSAGE ##{state.udp_message_count} ===")
    Logger.info("  From: #{inspect(from_ip)}:#{from_port}")
    Logger.info("  Size: #{byte_size(packet)} bytes")
    Logger.info("  Socket: #{inspect(socket)}")
    Logger.info("  Expected peer: #{inspect(state.peer_addr)}")

    # Build RecvInfo
    recv_info = %{
      from: state.peer_addr,
      to: state.local_addr
    }

    Logger.info("  Calling connection_recv...")

    # Process the packet
    state = case Native.connection_recv(state.conn_resource, packet, recv_info) do
      {:ok, bytes_read} ->
        Logger.info("  ✓ connection_recv succeeded: #{bytes_read} bytes processed")

        # Check if connection is now established
        Logger.info("  Checking if established...")
        case Native.connection_is_established(state.conn_resource) do
          {:ok, true} ->
            Logger.info("  ✓✓✓ CONNECTION IS ESTABLISHED! ✓✓✓")
            %{state | established: true}

          {:ok, false} ->
            Logger.info("  Connection not yet established")
            state

          {:error, reason} ->
            Logger.error("  ✗ connection_is_established error: #{inspect(reason)}")
            state
        end

      {:error, "done"} ->
        Logger.info("  connection_recv returned 'done' (no more data in packet)")
        state

      {:error, reason} ->
        Logger.error("  ✗ connection_recv error: #{inspect(reason)}")
        state
    end

    # Check for readable streams
    Logger.info("  Checking for readable streams...")
    case Native.connection_readable_streams(state.conn_resource) do
      {:ok, streams} ->
        Logger.info("  Readable streams: #{inspect(streams)}")

      {:error, reason} ->
        Logger.error("  ✗ connection_readable_streams error: #{inspect(reason)}")
    end

    # Send any packets generated in response
    Logger.info("  Sending pending packets...")
    case send_pending_packets(state) do
      {:ok, state} ->
        Logger.info("  ✓ Pending packets sent")
        {:noreply, state}

      {:error, reason} ->
        Logger.error("  ✗ Send error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.info("Received other message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp resolve_address(host, port) when is_binary(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, ip} -> {ip, port}
      {:error, _} ->
        case :inet.gethostbyname(to_charlist(host)) do
          {:ok, {:hostent, _name, _aliases, :inet, _length, [ip | _]}} -> {ip, port}
          {:error, reason} -> raise "Failed to resolve host #{host}: #{inspect(reason)}"
        end
    end
  end

  defp send_pending_packets(state) do
    case Native.connection_send(state.conn_resource) do
      {:ok, {packet, send_info}} ->
        {to_ip, to_port} = send_info.to
        :gen_udp.send(state.socket, to_ip, to_port, packet)
        Logger.debug("    Sent packet: #{byte_size(packet)} bytes to #{inspect(to_ip)}:#{to_port}")
        send_pending_packets(state)

      {:error, "done"} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_address({{a, b, c, d}, port}) when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) do
    <<a::8, b::8, c::8, d::8, port::16>>
  end

  defp format_address({ip_tuple, port}) when tuple_size(ip_tuple) == 8 do
    {s0, s1, s2, s3, s4, s5, s6, s7} = ip_tuple
    <<s0::16, s1::16, s2::16, s3::16, s4::16, s5::16, s6::16, s7::16, port::16>>
  end
end

# Run the test
Logger.info("Starting socket debug test...")

config = Quichex.Config.new!()
  |> Quichex.Config.set_application_protos(["hq-interop"])
  |> Quichex.Config.verify_peer(false)
  |> Quichex.Config.set_initial_max_data(10_000_000)
  |> Quichex.Config.set_initial_max_stream_data_bidi_local(1_000_000)
  |> Quichex.Config.set_initial_max_stream_data_bidi_remote(1_000_000)
  |> Quichex.Config.set_initial_max_stream_data_uni(1_000_000)
  |> Quichex.Config.set_initial_max_streams_bidi(100)
  |> Quichex.Config.set_initial_max_streams_uni(100)

{:ok, pid} = Quichex.Connection.Debug.start_link(
  host: "127.0.0.1",
  port: 4433,
  config: config
)

Logger.info("Connection started: #{inspect(pid)}")
Logger.info("Waiting for connection to establish...")

Process.sleep(500)

# Check if established
case GenServer.call(pid, :is_established?) do
  true ->
    Logger.info("✓ Connection is established, sending stream data...")

    # Open stream and send data
    {:ok, stream_id} = Quichex.Connection.open_stream(pid, :bidirectional)
    Logger.info("Opened stream #{stream_id}")

    :ok = Quichex.Connection.stream_send(pid, stream_id, "GET /\r\n", fin: true)
    Logger.info("Sent GET request on stream #{stream_id}")

    # Wait for response
    Logger.info("Waiting 1 second for response...")
    Process.sleep(1000)

    # Check readable streams
    case Quichex.Connection.readable_streams(pid) do
      {:ok, streams} ->
        Logger.info("Readable streams: #{inspect(streams)}")

        if stream_id in streams do
          case Quichex.Connection.stream_recv(pid, stream_id) do
            {:ok, data, fin} ->
              Logger.info("✓✓✓ RECEIVED STREAM DATA! ✓✓✓")
              Logger.info("Data: #{inspect(data)}")
              Logger.info("FIN: #{fin}")
            {:error, reason} ->
              Logger.error("Stream recv error: #{inspect(reason)}")
          end
        else
          Logger.warning("Stream #{stream_id} not readable yet")
        end

      {:error, reason} ->
        Logger.error("Failed to get readable streams: #{inspect(reason)}")
    end

  false ->
    Logger.error("Connection not established")
end

Logger.info("Test complete. Check logs above.")
