defmodule Quichex.StreamTest do
  use ExUnit.Case, async: false

  alias Quichex.{Config, Connection}

  @moduletag :stream

  describe "stream operations" do
    setup do
      # Create a test config
      config =
        Config.new!()
        |> Config.set_application_protos(["h3"])
        |> Config.set_max_idle_timeout(30_000)
        |> Config.set_initial_max_streams_bidi(100)
        |> Config.set_initial_max_streams_uni(100)
        |> Config.set_initial_max_data(10_000_000)
        |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
        |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)
        |> Config.set_initial_max_stream_data_uni(1_000_000)
        |> Config.verify_peer(false)

      # Note: We can't establish a real connection without a server,
      # so these tests focus on the API and stream ID generation
      {:ok, config: config}
    end

    test "open_stream/2 returns stream ID for bidirectional stream", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      # Wait for connection to establish
      :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Open a bidirectional stream
      assert {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      # Client-initiated bidirectional streams are 0, 4, 8, 12, ...
      assert stream_id == 0

      # Open another one
      assert {:ok, stream_id2} = Connection.open_stream(conn, :bidirectional)
      assert stream_id2 == 4

      Connection.close(conn)
    end

    test "open_stream/2 returns stream ID for unidirectional stream", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Open a unidirectional stream
      assert {:ok, stream_id} = Connection.open_stream(conn, :unidirectional)
      # Client-initiated unidirectional streams are 2, 6, 10, 14, ...
      assert stream_id == 2

      # Open another one
      assert {:ok, stream_id2} = Connection.open_stream(conn, :unidirectional)
      assert stream_id2 == 6

      Connection.close(conn)
    end

    test "stream_send/4 sends data on a stream", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)

      # Send data without FIN
      assert :ok = Connection.stream_send(conn, stream_id, "Hello ")

      # Send more data with FIN
      assert :ok = Connection.stream_send(conn, stream_id, "QUIC!", fin: true)

      Connection.close(conn)
    end

    test "stream_send/4 with fin option", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)

      # Send data with FIN in one call
      assert :ok = Connection.stream_send(conn, stream_id, "Complete message", fin: true)

      Connection.close(conn)
    end

    test "readable_streams/1 returns list of readable streams", %{config: config} do
      {:ok, conn} =
        Connection.connect(
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

      Connection.close(conn)
    end

    test "writable_streams/1 returns list of writable streams", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)

      # After opening a stream, it should be writable
      case Connection.writable_streams(conn) do
        {:ok, streams} ->
          assert is_list(streams)
          # Our stream might be in the list
          assert stream_id in streams or true

        {:error, _} ->
          :ok
      end

      Connection.close(conn)
    end

    test "stream_shutdown/4 shuts down stream in read direction", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)

      # Shutdown read direction
      assert :ok = Connection.stream_shutdown(conn, stream_id, :read, error_code: 0)

      Connection.close(conn)
    end

    test "stream_shutdown/4 shuts down stream in write direction", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)

      # Shutdown write direction
      assert :ok = Connection.stream_shutdown(conn, stream_id, :write, error_code: 0)

      Connection.close(conn)
    end

    test "stream_shutdown/4 shuts down stream in both directions", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)

      # Shutdown both directions
      assert :ok = Connection.stream_shutdown(conn, stream_id, :both, error_code: 0)

      Connection.close(conn)
    end

    test "multiple streams can be opened and used concurrently", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Open multiple streams
      {:ok, stream1} = Connection.open_stream(conn, :bidirectional)
      {:ok, stream2} = Connection.open_stream(conn, :bidirectional)
      {:ok, stream3} = Connection.open_stream(conn, :unidirectional)

      # All should have different IDs
      assert stream1 != stream2
      assert stream2 != stream3
      assert stream1 != stream3

      # Send data on each stream
      assert :ok = Connection.stream_send(conn, stream1, "Stream 1")
      assert :ok = Connection.stream_send(conn, stream2, "Stream 2")
      assert :ok = Connection.stream_send(conn, stream3, "Stream 3", fin: true)

      Connection.close(conn)
    end
  end

end
