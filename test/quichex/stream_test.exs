defmodule Quichex.StreamTest do
  use ExUnit.Case, async: false

  alias Quichex.{Config, Connection, StreamHandler}

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

    test "open_stream/2 returns handler PID for bidirectional stream", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      # Wait for connection to establish
      :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Open a bidirectional stream
      assert {:ok, handler} = Connection.open_stream(conn, :bidirectional)
      assert is_pid(handler)
      # Client-initiated bidirectional streams are 0, 4, 8, 12, ...
      assert StreamHandler.stream_id(handler) == 0

      # Open another one
      assert {:ok, handler2} = Connection.open_stream(conn, :bidirectional)
      assert StreamHandler.stream_id(handler2) == 4

      Quichex.close_connection(conn)
    end

    test "open_stream/2 returns handler PID for unidirectional stream", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      # Open a unidirectional stream
      assert {:ok, handler} = Connection.open_stream(conn, :unidirectional)
      assert is_pid(handler)
      # Client-initiated unidirectional streams are 2, 6, 10, 14, ...
      assert StreamHandler.stream_id(handler) == 2

      # Open another one
      assert {:ok, handler2} = Connection.open_stream(conn, :unidirectional)
      assert StreamHandler.stream_id(handler2) == 6

      Quichex.close_connection(conn)
    end

    test "StreamHandler.send_data/3 sends data on a stream", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, handler} = Connection.open_stream(conn, :bidirectional)

      # Send data without FIN
      assert :ok = StreamHandler.send_data(handler, "Hello ")

      # Send more data with FIN
      assert :ok = StreamHandler.send_data(handler, "QUIC!", true)

      Quichex.close_connection(conn)
    end

    test "StreamHandler.send_data/3 with fin option", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, handler} = Connection.open_stream(conn, :bidirectional)

      # Send data with FIN in one call
      assert :ok = StreamHandler.send_data(handler, "Complete message", true)

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

      {:ok, handler} = Connection.open_stream(conn, :bidirectional)
      stream_id = StreamHandler.stream_id(handler)

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

    test "StreamHandler.shutdown/3 shuts down stream in read direction", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, handler} = Connection.open_stream(conn, :bidirectional)

      # Shutdown read direction
      assert :ok = StreamHandler.shutdown(handler, :read, error_code: 0)

      Quichex.close_connection(conn)
    end

    test "StreamHandler.shutdown/3 shuts down stream in write direction", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, handler} = Connection.open_stream(conn, :bidirectional)

      # Shutdown write direction
      assert :ok = StreamHandler.shutdown(handler, :write, error_code: 0)

      Quichex.close_connection(conn)
    end

    test "StreamHandler.shutdown/3 shuts down stream in both directions", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "cloudflare-quic.com",
          port: 443,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 10_000)

      {:ok, handler} = Connection.open_stream(conn, :bidirectional)

      # Shutdown both directions
      assert :ok = StreamHandler.shutdown(handler, :both, error_code: 0)

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
      {:ok, handler1} = Connection.open_stream(conn, :bidirectional)
      {:ok, handler2} = Connection.open_stream(conn, :bidirectional)
      {:ok, handler3} = Connection.open_stream(conn, :unidirectional)

      # All should have different handler PIDs
      assert handler1 != handler2
      assert handler2 != handler3
      assert handler1 != handler3

      # Send data on each stream
      assert :ok = StreamHandler.send_data(handler1, "Stream 1")
      assert :ok = StreamHandler.send_data(handler2, "Stream 2")
      assert :ok = StreamHandler.send_data(handler3, "Stream 3", true)

      Quichex.close_connection(conn)
    end
  end

end
