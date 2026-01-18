defmodule Quichex.H3IntegrationTest do
  use ExUnit.Case, async: false

  alias Quichex.{H3, Native}

  @moduletag :integration
  @moduletag :external

  if System.get_env("QUICHEX_INTEGRATION") != "1" do
    @moduletag skip: "Set QUICHEX_INTEGRATION=1 to enable external HTTP/3 integration test"
  end

  test "fetches https://cloudflare-quic.com/ over HTTP/3" do
    host = "cloudflare-quic.com"
    {:ok, ip} = :inet.getaddr(String.to_charlist(host), :inet)

    {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(socket) end)

    {:ok, {local_ip, local_port}} = :inet.sockname(socket)
    peer_port = 443

    config =
      Native.config_new(0)
      |> Native.config_set_application_protos(["h3"])
      |> Native.config_verify_peer(false)
      |> Native.config_enable_dgram(true, 32, 32)
      |> Native.config_set_max_recv_udp_payload_size(1350)
      |> Native.config_set_max_send_udp_payload_size(1350)
      |> Native.config_set_initial_max_data(1_000_000)
      |> Native.config_set_initial_max_stream_data_bidi_local(1_000_000)
      |> Native.config_set_initial_max_stream_data_bidi_remote(1_000_000)
      |> Native.config_set_initial_max_stream_data_uni(1_000_000)
      |> Native.config_set_initial_max_streams_bidi(16)
      |> Native.config_set_initial_max_streams_uni(16)
      |> Native.config_set_disable_active_migration(true)

    scid = :crypto.strong_rand_bytes(16)
    local_addr = ipv4_bin(local_ip, local_port)
    peer_addr = ipv4_bin(ip, peer_port)

    {:ok, conn} =
      Native.connection_new_client(scid, host, local_addr, peer_addr, config, 4096)

    drive_until(conn, socket, ip, peer_port, local_ip, local_port, 5_000, fn ->
      match?({:ok, true}, Native.connection_is_established(conn))
    end)

    h3_config = H3.config_new()
    h3_conn = H3.conn_new_with_transport(conn, h3_config)

    headers = [
      {":method", "GET"},
      {":scheme", "https"},
      {":authority", host},
      {":path", "/"},
      {"user-agent", "quichex"}
    ]

    stream_id = H3.send_request(conn, h3_conn, headers, true)

    response_headers =
      drive_until(conn, socket, ip, peer_port, local_ip, local_port, 5_000, fn ->
        events = poll_h3(conn, h3_conn, [])

        case Enum.find(events, fn {id, event} ->
               id == stream_id and match?({:headers, _headers, _more}, event)
             end) do
          {^stream_id, {:headers, resp_headers, _more}} ->
            {:done, resp_headers}

          _ ->
            :cont
        end
      end)

    assert is_list(response_headers)
    assert Enum.any?(response_headers, fn {name, value} ->
             name == ":status" and value in ["200", "204", "301", "302"]
           end)
  end

  defp poll_h3(conn, h3_conn, acc) do
    case H3.conn_poll(conn, h3_conn) do
      :done -> acc
      {stream_id, event} -> poll_h3(conn, h3_conn, [{stream_id, event} | acc])
    end
  end

  defp drive_until(conn, socket, peer_ip, peer_port, local_ip, local_port, timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_drive(conn, socket, peer_ip, peer_port, local_ip, local_port, deadline, fun)
  end

  defp do_drive(conn, socket, peer_ip, peer_port, local_ip, local_port, deadline, fun) do
    flush_send(conn, socket, peer_ip, peer_port)

    recv_once(conn, socket, local_ip, local_port, 100)

    case Native.connection_timeout(conn) do
      {:ok, 0} -> Native.connection_on_timeout(conn)
      _ -> :ok
    end

    case fun.() do
      true ->
        :ok

      {:done, value} ->
        value

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("timed out waiting for HTTP/3 response")
        else
          Process.sleep(10)
          do_drive(conn, socket, peer_ip, peer_port, local_ip, local_port, deadline, fun)
        end
    end
  end

  defp flush_send(conn, socket, peer_ip, peer_port) do
    case Native.connection_send(conn) do
      {:ok, {packet, _send_info}} ->
        :ok = :gen_udp.send(socket, peer_ip, peer_port, packet)
        flush_send(conn, socket, peer_ip, peer_port)

      {:error, "done"} ->
        :ok

      {:error, reason} ->
        flunk("connection_send failed: #{inspect(reason)}")
    end
  end

  defp recv_once(conn, socket, local_ip, local_port, timeout) do
    case :gen_udp.recv(socket, 0, timeout) do
      {:ok, {addr, port, data}} ->
        recv_info = %{from: {addr, port}, to: {local_ip, local_port}}
        _ = Native.connection_recv(conn, data, recv_info)
        :ok

      {:error, :timeout} ->
        :ok
    end
  end

  defp ipv4_bin({a, b, c, d}, port) do
    <<a, b, c, d, port::16-big>>
  end

  defp ipv4_bin(ip, _port) do
    flunk("expected IPv4 address, got: #{inspect(ip)}")
  end
end
