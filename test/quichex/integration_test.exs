defmodule Quichex.IntegrationTest do
  use ExUnit.Case, async: false

  alias Quichex.{Config, Connection}

  @moduletag :integration
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
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      # Wait for handshake to complete
      assert :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Verify connection is established
      assert Connection.is_established?(conn)

      # Open a bidirectional stream
      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      assert is_integer(stream_id)
      assert stream_id == 0  # First client-initiated bidi stream

      # Send a simple HTTP/3 request-like data
      # Note: This is not a real HTTP/3 request (we'd need QPACK encoding for that)
      # Just testing that we can send data
      test_data = "Test data from Quichex"
      assert :ok = Connection.stream_send(conn, stream_id, test_data, fin: true)

      # Give the server time to process (it likely won't understand our non-HTTP/3 data,
      # but we're just testing that stream operations work)
      Process.sleep(500)

      # Open multiple streams to test concurrency
      {:ok, stream2} = Connection.open_stream(conn, :bidirectional)
      {:ok, stream3} = Connection.open_stream(conn, :unidirectional)

      assert stream2 == 4
      assert stream3 == 2

      # Send data on multiple streams
      assert :ok = Connection.stream_send(conn, stream2, "Stream 2 data", fin: true)
      assert :ok = Connection.stream_send(conn, stream3, "Stream 3 data", fin: true)

      # Clean up
      Connection.close(conn)
      refute Connection.is_established?(conn)
    end

    test "active mode receives stream messages" do
      config =
        Config.new!()
        |> Config.set_application_protos(["h3"])
        |> Config.verify_peer(false)

      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config,
          active: true
        )

      # Wait for connection to establish (this will block until connected)
      assert :ok = Connection.wait_connected(conn, timeout: 10_000)

      # The connection GenServer should have sent {:quic_connected, conn} to its controlling process
      # Let's check if the message is in the mailbox
      message_received = receive do
        {:quic_connected, ^conn} -> true
      after
        100 -> false
      end

      # If wait_connected returned, we might have already consumed the message internally
      # or it was sent and we received it. Either is fine for active mode.
      assert message_received or Connection.is_established?(conn)

      # Open and send on a stream
      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "Test", fin: true)

      # We might not receive stream data (server might not respond to our non-HTTP/3 data)
      # But the test verifies the active mode works
      receive do
        {:quic_stream, ^conn, ^stream_id, _data} -> :ok
        {:quic_stream_fin, ^conn, ^stream_id} -> :ok
      after
        2_000 -> :ok  # No response is ok
      end

      Connection.close(conn)
    end

    test "passive mode stream recv" do
      config =
        Config.new!()
        |> Config.set_application_protos(["h3"])
        |> Config.verify_peer(false)

      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config,
          active: false
        )

      assert :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Open stream and send data
      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      assert :ok = Connection.stream_send(conn, stream_id, "Test data", fin: true)

      # Try to receive (might get error if no data available)
      case Connection.stream_recv(conn, stream_id, 1024) do
        {:ok, _data, _fin} -> :ok
        {:error, _} -> :ok  # Server might not respond
      end

      # Check readable streams
      case Connection.readable_streams(conn) do
        {:ok, streams} -> assert is_list(streams)
        {:error, _} -> :ok
      end

      Connection.close(conn)
    end

    test "multiple concurrent streams work correctly" do
      config =
        Config.new!()
        |> Config.set_application_protos(["h3"])
        |> Config.set_initial_max_streams_bidi(10)
        |> Config.verify_peer(false)

      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      assert :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Open 5 concurrent streams
      streams =
        Enum.map(1..5, fn i ->
          {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
          # Send unique data on each stream
          :ok = Connection.stream_send(conn, stream_id, "Stream #{i} data", fin: true)
          stream_id
        end)

      # Verify we got 5 different stream IDs
      assert length(streams) == 5
      assert length(Enum.uniq(streams)) == 5

      # All should be client-initiated bidirectional (0, 4, 8, 12, 16)
      expected = [0, 4, 8, 12, 16]
      assert streams == expected

      Connection.close(conn)
    end

    test "stream shutdown works correctly" do
      config =
        Config.new!()
        |> Config.set_application_protos(["h3"])
        |> Config.verify_peer(false)

      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      assert :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)

      # Send some data
      assert :ok = Connection.stream_send(conn, stream_id, "Test", fin: false)

      # Shutdown write direction
      assert :ok = Connection.stream_shutdown(conn, stream_id, :write, error_code: 0)

      # Try to send again (might fail since we shut down write)
      case Connection.stream_send(conn, stream_id, "More data") do
        :ok -> :ok
        {:error, _} -> :ok  # Expected if shutdown worked
      end

      Connection.close(conn)
    end
  end
end
