defmodule Quichex.WebTransportIntegrationTest do
  use ExUnit.Case, async: false

  alias Quichex.{H3, Native, WebTransport}
  import Quichex.Native.TestHelpers

  @moduletag :integration

  test "local WebTransport CONNECT and datagrams over H3" do
    client_opts = [protos: ["h3"]]
    server_opts = [protos: ["h3"]]

    {{_client_config, client}, {_server_config, server}} =
      handshake_pair(client_opts: client_opts, server_opts: server_opts)

    client_h3_config = H3.config_new() |> H3.config_enable_extended_connect(true)
    server_h3_config = H3.config_new() |> H3.config_enable_extended_connect(true)

    client_h3 = H3.conn_new_with_transport(client, client_h3_config)
    server_h3 = H3.conn_new_with_transport(server, server_h3_config)

    stream_id =
      WebTransport.connect(client, client_h3, "localhost", "/moq",
        origin: "https://localhost",
        user_agent: "quichex-test"
      )

    request_headers =
      await_headers(client, server, client_h3, server_h3, stream_id, :server)

    assert header_value(request_headers, ":method") == "CONNECT"
    assert header_value(request_headers, ":protocol") == "webtransport"

    H3.send_response(server, server_h3, stream_id, [{":status", "200"}], true)

    response_headers =
      await_headers(client, server, client_h3, server_h3, stream_id, :client)

    assert WebTransport.response_status(response_headers) == 200

    WebTransport.send_datagram(client, stream_id, "ping")

    {:ok, ^stream_id, "ping"} =
      await_datagram(client, server, stream_id, :server)

    WebTransport.send_datagram(server, stream_id, "pong")

    {:ok, ^stream_id, "pong"} =
      await_datagram(client, server, stream_id, :client)
  end

  defp handshake_pair(opts) do
    {client_port, server_port} = handshake_ports(opts)

    client_opts =
      [local_port: client_port, peer_port: server_port]
      |> Keyword.merge(Keyword.get(opts, :client_opts, []))

    server_opts =
      [local_port: server_port, peer_port: client_port]
      |> Keyword.merge(Keyword.get(opts, :server_opts, []))

    {client_config, client_conn} = create_connection(client_opts)
    {server_config, server_conn} = accept_connection(server_opts)

    pump_until(client_conn, server_conn, fn ->
      match?({:ok, true}, Native.connection_is_established(client_conn)) and
        match?({:ok, true}, Native.connection_is_established(server_conn))
    end)

    {{client_config, client_conn}, {server_config, server_conn}}
  end

  defp handshake_ports(opts) do
    base = System.unique_integer([:positive])
    client_port = Keyword.get(opts, :client_port, 46_000 + rem(base, 1000))
    server_port = Keyword.get(opts, :server_port, 47_000 + rem(base, 1000))
    {client_port, server_port}
  end

  defp pump_until(client, server, predicate, attempts \\ 0)

  defp pump_until(_client, _server, _predicate, attempts) when attempts >= 300 do
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
        recv_info = %{from: send_info.from, to: send_info.to}
        assert {:ok, _} = Native.connection_recv(receiver, packet, recv_info)
        pump_direction(sender, receiver)

      {:error, "done"} ->
        :ok

      {:error, other} ->
        flunk("send failed with #{inspect(other)}")
    end
  end

  defp await_headers(client, server, client_h3, server_h3, stream_id, role, attempts \\ 0)

  defp await_headers(_client, _server, _client_h3, _server_h3, _stream_id, _role, attempts)
       when attempts >= 300 do
    flunk("timed out waiting for H3 headers")
  end

  defp await_headers(client, server, client_h3, server_h3, stream_id, role, attempts) do
    pump_direction(client, server)
    pump_direction(server, client)

    events =
      case role do
        :client -> poll_h3(client, client_h3, [])
        :server -> poll_h3(server, server_h3, [])
      end

    case Enum.find(events, fn {id, event} ->
           id == stream_id and match?({:headers, _headers, _more}, event)
         end) do
      {^stream_id, {:headers, headers, _more}} ->
        headers

      _ ->
        await_headers(client, server, client_h3, server_h3, stream_id, role, attempts + 1)
    end
  end

  defp await_datagram(client, server, stream_id, role, attempts \\ 0)

  defp await_datagram(_client, _server, _stream_id, _role, attempts) when attempts >= 300 do
    flunk("timed out waiting for datagram")
  end

  defp await_datagram(client, server, stream_id, role, attempts) do
    pump_direction(client, server)
    pump_direction(server, client)

    receiver = if role == :client, do: client, else: server

    case WebTransport.recv_datagram(receiver, 1350) do
      {:ok, ^stream_id, payload} ->
        {:ok, stream_id, payload}

      :done ->
        await_datagram(client, server, stream_id, role, attempts + 1)

      {:ok, _flow_id, _payload} ->
        await_datagram(client, server, stream_id, role, attempts + 1)
    end
  end

  defp poll_h3(conn, h3_conn, acc) do
    case H3.conn_poll(conn, h3_conn) do
      :done -> acc
      {stream_id, event} -> poll_h3(conn, h3_conn, [{stream_id, event} | acc])
    end
  end

  defp header_value(headers, name) do
    case Enum.find(headers, fn {key, _value} -> key == name end) do
      {^name, value} -> value
      _ -> nil
    end
  end
end
