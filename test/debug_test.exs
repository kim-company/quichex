# Debug test - receives messages in the parent process to see what's happening
#
# Start server first:
#   cd ../quiche && RUST_LOG=trace target/debug/quiche-server \
#     --cert ../quichex/priv/cert.crt --key ../quichex/priv/cert.key \
#     --listen 127.0.0.1:4433 --no-retry

require Logger

defmodule DebugTest do
  def run do
    Logger.info("=== Debug Test Starting ===")

    # Create config
    config = Quichex.Config.new!()
      |> Quichex.Config.set_application_protos(["hq-interop"])
      |> Quichex.Config.verify_peer(false)

    Logger.info("Connecting to server...")

    {:ok, conn_pid} = Quichex.Connection.connect(
      host: "127.0.0.1",
      port: 4433,
      config: config
    )

    Logger.info("Connection PID: #{inspect(conn_pid)}")

    # Wait for connection established message
    receive do
      {:quic_connected, ^conn_pid} ->
        Logger.info("✓ Received :quic_connected message")
    after
      5000 ->
        Logger.error("✗ Timeout waiting for :quic_connected")
        System.halt(1)
    end

    # Open stream and send data
    {:ok, stream_id} = Quichex.Connection.open_stream(conn_pid, :bidirectional)
    Logger.info("Opened stream #{stream_id}")

    :ok = Quichex.Connection.stream_send(conn_pid, stream_id, "GET /\r\n", fin: true)
    Logger.info("Sent GET request on stream #{stream_id}")

    # Wait for stream data messages
    Logger.info("Waiting for stream data...")

    wait_for_stream_data(conn_pid, stream_id, 5000)

    Logger.info("Closing connection...")
    Quichex.Connection.close(conn_pid)

    Logger.info("=== Test Complete ===")
  end

  defp wait_for_stream_data(conn_pid, stream_id, timeout) do
    receive do
      {:quic_stream, ^conn_pid, ^stream_id, data} ->
        Logger.info("✓ Received stream data: #{inspect(data)}")
        wait_for_stream_data(conn_pid, stream_id, timeout)

      {:quic_stream_fin, ^conn_pid, ^stream_id} ->
        Logger.info("✓ Received stream FIN on stream #{stream_id}")

      {:quic_connection_closed, ^conn_pid, error_code, reason} ->
        Logger.info("Connection closed: error_code=#{error_code}, reason=#{inspect(reason)}")

      other ->
        Logger.info("Received other message: #{inspect(other)}")
        wait_for_stream_data(conn_pid, stream_id, timeout)
    after
      timeout ->
        Logger.warning("✗ Timeout waiting for stream data")

        # Try to manually check for readable streams
        case Quichex.Connection.readable_streams(conn_pid) do
          {:ok, streams} ->
            Logger.info("Readable streams (manual check): #{inspect(streams)}")

            if stream_id in streams do
              case Quichex.Connection.stream_recv(conn_pid, stream_id) do
                {:ok, data, fin} ->
                  Logger.info("✓ Manual read succeeded: #{inspect(data)}, fin=#{fin}")
                {:error, reason} ->
                  Logger.error("✗ Manual read failed: #{inspect(reason)}")
              end
            end

          {:error, reason} ->
            Logger.error("✗ Failed to get readable streams: #{inspect(reason)}")
        end
    end
  end
end

DebugTest.run()
