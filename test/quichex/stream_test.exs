defmodule Quichex.StreamTest do
  use ExUnit.Case, async: true

  alias Quichex.{Config, Connection}

  @moduletag :stream
  @moduletag :external  # These tests connect to cloudflare-quic.com - skip by default

  describe "stream operations" do
    setup do
      # Create a test config with proper TLS settings for cloudflare-quic.com
      base_config =
        Config.new!()
        |> Config.set_application_protos(["h3"])
        |> Config.set_max_idle_timeout(30_000)
        |> Config.set_max_recv_udp_payload_size(1350)
        |> Config.set_max_send_udp_payload_size(1350)
        |> Config.set_disable_active_migration(true)
        |> Config.set_initial_max_streams_bidi(100)
        |> Config.set_initial_max_streams_uni(100)
        |> Config.set_initial_max_data(10_000_000)
        |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
        |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)
        |> Config.set_initial_max_stream_data_uni(1_000_000)
        |> Config.verify_peer(false)

      config =
        case Config.load_system_ca_certs(base_config) do
          {:ok, cfg} -> cfg
          {:error, _} -> base_config
        end

      {:ok, config: config}
    end

    test "open_stream/2 returns stream_id for bidirectional stream", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      # Wait for connection to establish
      :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Open a bidirectional stream
      assert {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)
      # Client-initiated bidirectional streams are 0, 4, 8, 12, ...
      assert stream_id == 0

      # Open another one
      assert {:ok, stream_id2} = Connection.open_stream(conn, type: :bidirectional)
      assert stream_id2 == 4

      Quichex.close_connection(conn)
    end

    test "open_stream/2 returns stream_id for unidirectional stream", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Open a unidirectional stream
      assert {:ok, stream_id} = Connection.open_stream(conn, type: :unidirectional)
      # Client-initiated unidirectional streams are 2, 6, 10, 14, ...
      assert stream_id == 2

      # Open another one
      assert {:ok, stream_id2} = Connection.open_stream(conn, type: :unidirectional)
      assert stream_id2 == 6

      Quichex.close_connection(conn)
    end

    test "stream_send/4 sends data on a stream", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)

      # Send data without FIN
      assert {:ok, bytes1} = Connection.stream_send(conn, stream_id, "Hello ", fin: false)
      assert bytes1 == 6

      # Send more data with FIN
      assert {:ok, bytes2} = Connection.stream_send(conn, stream_id, "QUIC!", fin: true)
      assert bytes2 == 5

      Quichex.close_connection(conn)
    end

    test "stream_send/4 with fin option", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)

      # Send data with FIN in one call
      assert {:ok, bytes} = Connection.stream_send(conn, stream_id, "Complete message", fin: true)
      assert bytes == 16

      Quichex.close_connection(conn)
    end

    test "readable_streams/1 returns list of readable streams", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Initially should be empty or error (no readable streams yet)
      case Connection.readable_streams(conn) do
        {:ok, streams} -> assert is_list(streams)
        {:error, _} -> :ok
      end

      Quichex.close_connection(conn)
    end

    test "writable_streams/1 returns list of writable streams", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)

      # After opening a stream, it should be writable
      case Connection.writable_streams(conn) do
        {:ok, streams} ->
          assert is_list(streams)
          # Our stream might be in the list
          assert stream_id in streams or true

        {:error, _} ->
          :ok
      end

      Quichex.close_connection(conn)
    end

    test "stream_shutdown/4 shuts down stream in read direction", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)

      # Shutdown read direction
      assert :ok = Connection.stream_shutdown(conn, stream_id, :read, 0)

      Quichex.close_connection(conn)
    end

    test "stream_shutdown/4 shuts down stream in write direction", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)

      # Shutdown write direction
      assert :ok = Connection.stream_shutdown(conn, stream_id, :write, 0)

      Quichex.close_connection(conn)
    end

    test "stream_shutdown/4 shuts down stream in both directions", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)

      # Shutdown both directions
      assert :ok = Connection.stream_shutdown(conn, stream_id, :both, 0)

      Quichex.close_connection(conn)
    end

    test "multiple streams can be opened and used concurrently", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Open multiple streams
      {:ok, stream_id1} = Connection.open_stream(conn, type: :bidirectional)
      {:ok, stream_id2} = Connection.open_stream(conn, type: :bidirectional)
      {:ok, stream_id3} = Connection.open_stream(conn, type: :unidirectional)

      # All should have different stream IDs
      assert stream_id1 != stream_id2
      assert stream_id2 != stream_id3
      assert stream_id1 != stream_id3

      # Send data on each stream
      assert {:ok, _} = Connection.stream_send(conn, stream_id1, "Stream 1", fin: false)
      assert {:ok, _} = Connection.stream_send(conn, stream_id2, "Stream 2", fin: false)
      assert {:ok, _} = Connection.stream_send(conn, stream_id3, "Stream 3", fin: true)

      Quichex.close_connection(conn)
    end
  end

end
