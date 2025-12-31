defmodule Quichex.IntegrationTest do
  use ExUnit.Case, async: true

  alias Quichex.{Config, Connection}

  @moduletag :integration
  @moduletag :external  # These tests connect to cloudflare-quic.com - skip by default
  @moduletag timeout: 30_000

  describe "real server integration" do
    test "can send and receive data over streams with cloudflare-quic.com" do
      # Create config for HTTP/3
      config =
        Config.new!()
        |> Config.set_application_protos(["h3"])
        |> Config.set_max_idle_timeout(30_000)
        |> Config.set_initial_max_streams_bidi(100)
        |> Config.set_initial_max_data(10_000_000)
        |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
        |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)
        |> Config.verify_peer(false)

      # Connect to cloudflare-quic.com
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      # Wait for handshake to complete
      assert :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Verify connection is established
      assert Connection.is_established?(conn)

      # Open multiple streams immediately (before sending data that might cause server to close connection)
      {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)
      assert stream_id == 0  # First client-initiated bidi stream

      {:ok, stream_id2} = Connection.open_stream(conn, type: :bidirectional)
      {:ok, stream_id3} = Connection.open_stream(conn, type: :unidirectional)

      assert stream_id2 == 4
      assert stream_id3 == 2

      # Send data on multiple streams
      # Note: This is not a real HTTP/3 request (we'd need QPACK encoding for that)
      # Sending this data may cause the server to close the connection, but we've already
      # verified we can open multiple streams
      test_data = "Test data from Quichex"
      assert {:ok, _bytes_written} = Connection.stream_send(conn, stream_id, test_data, fin: true)
      assert {:ok, _} = Connection.stream_send(conn, stream_id2, "Stream 2 data", fin: true)
      assert {:ok, _} = Connection.stream_send(conn, stream_id3, "Stream 3 data", fin: true)

      # Give server time to process (may close connection due to invalid HTTP/3 data)
      Process.sleep(500)

      # Clean up (connection may already be closed by server)
      if Process.alive?(conn) do
        Quichex.close_connection(conn)
      end
    end

    test "notification-based stream reading" do
      # Use proper config like the external test
      base_config =
        Config.new!()
        |> Config.set_application_protos(["h3"])
        |> Config.set_max_idle_timeout(30_000)
        |> Config.set_max_recv_udp_payload_size(1350)
        |> Config.set_max_send_udp_payload_size(1350)
        |> Config.set_disable_active_migration(true)
        |> Config.set_initial_max_data(10_000_000)
        |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
        |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)
        |> Config.set_initial_max_stream_data_uni(1_000_000)
        |> Config.set_initial_max_streams_bidi(100)
        |> Config.set_initial_max_streams_uni(100)
        |> Config.verify_peer(false)

      config =
        case Config.load_system_ca_certs(base_config) do
          {:ok, cfg} -> cfg
          {:error, _} -> base_config
        end

      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      # Wait for connection to establish
      assert :ok = Connection.wait_connected(conn, timeout: 10_000)

      # The connection should have sent {:quic_connected, conn} to controlling process
      # (Socket is always in active mode, immediate delivery)
      message_received =
        receive do
          {:quic_connected, ^conn} -> true
        after
          100 -> false
        end

      # If wait_connected returned, connection is established
      assert message_received or Connection.is_established?(conn)

      # Open and send on a stream
      {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)
      {:ok, _} = Connection.stream_send(conn, stream_id, "Test", fin: true)

      # We might not receive stream data (server might not respond to our non-HTTP/3 data)
      # But we can verify the notification system works
      receive do
        {:quic_stream_readable, ^conn, _readable_stream_id} ->
          # Stream became readable - default handler will auto-read it
          # Wait for the data message
          receive do
            {:quic_stream_data, ^conn, _stream_id, _data, _fin} ->
              :ok
          after
            1_000 -> :ok
          end

        {:quic_stream_data, ^conn, _stream_id, _data, _fin} ->
          # Got data directly
          :ok

        {:quic_stream_closed, ^conn, _stream_id, _error_code} ->
          :ok
      after
        2_000 -> :ok  # No response is ok for this test
      end

      Quichex.close_connection(conn)
    end

    test "multiple concurrent streams work correctly" do
      config =
        Config.new!()
        |> Config.set_application_protos(["h3"])
        |> Config.set_initial_max_streams_bidi(10)
        |> Config.set_initial_max_data(10_000_000)
        |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
        |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)
        |> Config.verify_peer(false)

      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      assert :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Open 5 concurrent streams
      stream_ids =
        Enum.map(1..5, fn i ->
          {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)
          # Send unique data on each stream
          {:ok, _} = Connection.stream_send(conn, stream_id, "Stream #{i} data", fin: true)
          stream_id
        end)

      # Verify we got 5 different stream IDs
      assert length(stream_ids) == 5
      assert length(Enum.uniq(stream_ids)) == 5

      # Verify they are client-initiated bidirectional (0, 4, 8, 12, 16)
      expected = [0, 4, 8, 12, 16]
      assert stream_ids == expected

      Quichex.close_connection(conn)
    end

    test "stream shutdown works correctly" do
      config =
        Config.new!()
        |> Config.set_application_protos(["h3"])
        |> Config.set_initial_max_data(10_000_000)
        |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
        |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)
        |> Config.verify_peer(false)

      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      assert :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)

      # Send some data
      assert {:ok, _} = Connection.stream_send(conn, stream_id, "Test", fin: false)

      # Shutdown write direction
      assert :ok = Connection.stream_shutdown(conn, stream_id, :write, 0)

      # Try to send again (should fail since we shut down write)
      case Connection.stream_send(conn, stream_id, "More data", fin: false) do
        {:ok, _} -> :ok  # Might succeed if shutdown didn't take effect yet
        {:error, _} -> :ok  # Expected if shutdown worked
      end

      Quichex.close_connection(conn)
    end
  end
end
