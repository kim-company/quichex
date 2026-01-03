defmodule Quichex.Native.ConnectionTest do
  use ExUnit.Case, async: true

  alias Quichex.Native
  alias Quichex.Native.ConnectionStats
  import Quichex.Native.TestHelpers

  describe "metadata accessors" do
    test "expose IDs and connection state" do
      {_config, conn} = create_connection()

      assert {:ok, trace} = Native.connection_trace_id(conn)
      assert is_binary(trace)

      assert {:ok, scid} = Native.connection_source_id(conn)
      assert byte_size(scid) == 16

      assert {:ok, dcid} = Native.connection_destination_id(conn)
      assert byte_size(dcid) == 16

      assert {:ok, false} = Native.connection_is_established(conn)
      assert {:ok, false} = Native.connection_is_closed(conn)
      assert {:ok, false} = Native.connection_is_draining(conn)
      assert {:ok, false} = Native.connection_is_in_early_data(conn)
      assert {:ok, false} = Native.connection_is_resumed(conn)
      assert {:ok, false} = Native.connection_is_timed_out(conn)
      assert {:ok, false} = Native.connection_is_server(conn)

      assert {:ok, %ConnectionStats{} = stats} = Native.connection_stats(conn)
      assert stats.sent == 0
      assert {:ok, nil} = Native.connection_peer_error(conn)
      assert {:ok, nil} = Native.connection_local_error(conn)
      assert {:ok, nil} = Native.connection_peer_transport_params(conn)

      assert {:ok, proto} = Native.connection_application_proto(conn)
      assert is_binary(proto)

      assert {:ok, nil} = Native.connection_peer_cert(conn)
      assert {:ok, nil} = Native.connection_session(conn)
      assert {:ok, nil} = Native.connection_server_name(conn)
    end
  end

  describe "datagram helpers" do
    test "report queue lengths and enforce read/write semantics" do
      {_config, conn} = create_connection()

      assert {:ok, len} = Native.connection_dgram_max_writable_len(conn)
      assert is_integer(len)
      assert len > 0

      assert {:ok, 0} = Native.connection_dgram_recv_queue_len(conn)
      assert {:ok, 0} = Native.connection_dgram_recv_queue_byte_size(conn)
      assert {:ok, 0} = Native.connection_dgram_send_queue_len(conn)
      assert {:ok, 0} = Native.connection_dgram_send_queue_byte_size(conn)

      payload = :crypto.strong_rand_bytes(1200)
      assert {:error, "done"} = Native.connection_dgram_send(conn, payload)
      assert {:error, "done"} = Native.connection_dgram_recv(conn, 1200)
    end

    test "keylog path setup" do
      {_config, conn} = create_connection()
      path = Path.join(System.tmp_dir!(), "quichex-keylog-#{System.unique_integer()}")
      on_exit(fn -> File.rm(path) end)

      assert :ok = ok!(Native.connection_set_keylog_path(conn, path))
      assert File.exists?(path)
    end
  end

  describe "stream and queue queries" do
    test "report empty queues and close cleanly" do
      {_config, conn} = create_connection()

      assert {:ok, []} = Native.connection_readable_streams(conn)
      assert {:ok, []} = Native.connection_writable_streams(conn)
      assert {:ok, false} = Native.connection_stream_finished(conn, 0)

      assert {:error, reason} = Native.connection_stream_send(conn, 0, "hello", true)
      assert is_binary(reason)

      assert {:ok, timeout} = Native.connection_timeout(conn)
      assert is_integer(timeout)

      assert :ok = ok!(Native.connection_close(conn, false, 0, "bye"))
    end
  end

  describe "client/server interoperability" do
    test "complete handshake, exchange streams, and deliver datagrams" do
      {{_client_config, client}, {_server_config, server}} = handshake_pair()

      assert {:ok, true} = Native.connection_is_established(client)
      assert {:ok, true} = Native.connection_is_established(server)
      assert {:ok, false} = Native.connection_is_server(client)
      assert {:ok, true} = Native.connection_is_server(server)

      assert {:ok, writable} = Native.connection_writable_streams(client)
      assert Enum.all?(writable, &is_integer/1)

      assert {:ok, %ConnectionStats{} = c_stats} = Native.connection_stats(client)
      assert c_stats.sent > 0
      assert c_stats.recv >= 0

      payload = "hello over quic"
      payload_len = byte_size(payload)
      assert {:ok, ^payload_len} = Native.connection_stream_send(client, 0, payload, true)

      pump_until(client, server, fn -> stream_readable?(server, 0) end)

      assert {:ok, [0]} = Native.connection_readable_streams(server)
      assert {:ok, {data, fin?}} = Native.connection_stream_recv(server, 0, 4096)
      assert data == payload
      assert fin?
      assert {:ok, true} = Native.connection_stream_finished(server, 0)

      datagram = :crypto.strong_rand_bytes(48)
      datagram_len = byte_size(datagram)
      assert {:ok, ^datagram_len} = Native.connection_dgram_send(client, datagram)

      pump_until(client, server, fn ->
        match?({:ok, len} when len > 0, Native.connection_dgram_recv_queue_len(server))
      end)

      assert {:ok, 1} = Native.connection_dgram_recv_queue_len(server)
      assert {:ok, ^datagram_len} = Native.connection_dgram_recv_queue_byte_size(server)
      assert {:ok, received} = Native.connection_dgram_recv(server, 1350)
      assert datagram == received
      assert {:ok, 0} = Native.connection_dgram_recv_queue_len(server)
    end
  end

  describe "client/server via :socket" do
    @tag timeout: 120
    test "handshake, stream, and datagram over real UDP sockets" do
      {client_sock, client_addr} = open_udp_socket()
      {server_sock, server_addr} = open_udp_socket()

      on_exit(fn ->
        close_udp_socket(client_sock)
        close_udp_socket(server_sock)
      end)

      {_client_config, client} =
        create_connection(local_port: client_addr.port, peer_port: server_addr.port)

      {_server_config, server} =
        accept_connection(local_port: server_addr.port, peer_port: client_addr.port)

      pump_udp_until(
        client,
        server,
        client_sock,
        client_addr,
        server_sock,
        server_addr,
        fn ->
          match?({:ok, true}, Native.connection_is_established(client)) and
            match?({:ok, true}, Native.connection_is_established(server))
        end
      )

      payload = "socket hello"
      payload_len = byte_size(payload)
      assert {:ok, ^payload_len} = Native.connection_stream_send(client, 0, payload, true)

      pump_udp_until(
        client,
        server,
        client_sock,
        client_addr,
        server_sock,
        server_addr,
        fn -> stream_readable?(server, 0) end
      )

      assert {:ok, {data, fin?}} = Native.connection_stream_recv(server, 0, 4096)
      assert data == payload
      assert fin?

      datagram = :crypto.strong_rand_bytes(32)
      datagram_len = byte_size(datagram)
      assert {:ok, ^datagram_len} = Native.connection_dgram_send(client, datagram)

      pump_udp_until(
        client,
        server,
        client_sock,
        client_addr,
        server_sock,
        server_addr,
        fn ->
          match?(
            {:ok, len} when len > 0,
            Native.connection_dgram_recv_queue_len(server)
          )
        end
      )

      assert {:ok, received} = Native.connection_dgram_recv(server, 1350)
      assert received == datagram
    end
  end

  defp handshake_pair do
    {client_config, client_conn} = create_connection(local_port: 4000, peer_port: 5000)
    {server_config, server_conn} = accept_connection(local_port: 5000, peer_port: 4000)

    pump_until(client_conn, server_conn, fn ->
      match?({:ok, true}, Native.connection_is_established(client_conn)) and
        match?({:ok, true}, Native.connection_is_established(server_conn))
    end)

    {{client_config, client_conn}, {server_config, server_conn}}
  end

  defp pump_until(client, server, predicate, attempts \\ 0)

  defp pump_until(_client, _server, _predicate, attempts) when attempts >= 200 do
    flunk("condition not satisfied after #{attempts} send/recv iterations")
  end

  defp pump_until(client, server, predicate, attempts) do
    if predicate.() do
      :ok
    else
      pump_direction(client, server)
      pump_direction(server, client)
      pump_until(client, server, predicate, attempts + 1)
    end
  end

  defp pump_direction(sender, receiver) do
    case Native.connection_send(sender) do
      {:ok, {packet, send_info}} ->
        recv_info = send_info_to_recv_info(send_info)
        assert {:ok, _} = Native.connection_recv(receiver, packet, recv_info)
        pump_direction(sender, receiver)

      {:error, "done"} ->
        :ok

      {:error, other} ->
        flunk("send failed with #{inspect(other)}")
    end
  end

  defp send_info_to_recv_info(%{from: from, to: to}) do
    %{from: from, to: to}
  end

  defp stream_readable?(conn, stream_id) do
    case Native.connection_readable_streams(conn) do
      {:ok, streams} -> stream_id in streams
      _ -> false
    end
  end

  defp pump_udp_until(
         client,
         server,
         client_sock,
         client_addr,
         server_sock,
         server_addr,
         predicate,
         attempts \\ 0
       )

  defp pump_udp_until(
         _client,
         _server,
         _client_sock,
         _client_addr,
         _server_sock,
         _server_addr,
         _predicate,
         attempts
       )
       when attempts >= 400 do
    flunk("socket condition not satisfied after #{attempts} iterations")
  end

  defp pump_udp_until(
         client,
         server,
         client_sock,
         client_addr,
         server_sock,
         server_addr,
         predicate,
         attempts
       ) do
    if predicate.() do
      :ok
    else
      udp_step(client, server, client_sock, client_addr, server_sock, server_addr)

      pump_udp_until(
        client,
        server,
        client_sock,
        client_addr,
        server_sock,
        server_addr,
        predicate,
        attempts + 1
      )
    end
  end

  defp udp_step(client, server, client_sock, client_addr, server_sock, server_addr) do
    flush_udp(client, client_sock, server_addr)
    drain_udp(server, server_sock, server_addr)
    flush_udp(server, server_sock, client_addr)
    drain_udp(client, client_sock, client_addr)
  end

  defp flush_udp(conn, socket, peer_addr) do
    case Native.connection_send(conn) do
      {:ok, {packet, _send_info}} ->
        :ok = :socket.sendto(socket, packet, peer_addr)
        flush_udp(conn, socket, peer_addr)

      {:error, "done"} ->
        :ok

      {:error, other} ->
        flunk("send failed with #{inspect(other)}")
    end
  end

  defp drain_udp(conn, socket, local_addr) do
    case :socket.recvfrom(socket, 0, [], 0) do
      {:ok, {remote_addr, packet}} ->
        recv_info = recv_info_from(remote_addr, local_addr)
        assert {:ok, _} = Native.connection_recv(conn, packet, recv_info)
        drain_udp(conn, socket, local_addr)

      {:error, :timeout} ->
        :ok
    end
  end

  defp recv_info_from(remote_addr, local_addr) do
    %{
      from: {remote_addr.addr, remote_addr.port},
      to: {local_addr.addr, local_addr.port}
    }
  end

  defp open_udp_socket(port \\ 0) do
    {:ok, socket} = :socket.open(:inet, :dgram, :udp)
    :ok = :socket.bind(socket, %{family: :inet, addr: {127, 0, 0, 1}, port: port})
    {:ok, addr} = :socket.sockname(socket)
    {socket, addr}
  end

  defp close_udp_socket(socket) do
    case :socket.close(socket) do
      :ok -> :ok
      {:error, :closed} -> :ok
    end
  end
end
