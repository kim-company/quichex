# Manual test script for testing Quichex client against quiche-server
#
# Before running this test, start quiche-server in another terminal:
#
#   cd ../quiche
#   RUST_LOG=debug target/debug/quiche-server \
#     --cert ../quichex/priv/cert.crt \
#     --key ../quichex/priv/cert.key \
#     --listen 127.0.0.1:4433 \
#     --no-retry
#
# Then run this script:
#   mix run test/manual_server_test.exs

require Logger

defmodule ManualServerTest do
  def run do
    # Flush any old messages
    receive do
      msg -> Logger.info("Flushing old message: #{inspect(msg)}")
    after
      0 -> :ok
    end

    Logger.info("Starting manual test against quiche-server on 127.0.0.1:4433")

    # Create config with proper flow control settings
    config = Quichex.Config.new!()
      |> Quichex.Config.set_application_protos(["hq-interop"])
      |> Quichex.Config.verify_peer(false)
      # Set flow control limits so server can send data
      |> Quichex.Config.set_initial_max_data(10_000_000)
      |> Quichex.Config.set_initial_max_stream_data_bidi_local(1_000_000)
      |> Quichex.Config.set_initial_max_stream_data_bidi_remote(1_000_000)
      |> Quichex.Config.set_initial_max_stream_data_uni(1_000_000)
      |> Quichex.Config.set_initial_max_streams_bidi(100)
      |> Quichex.Config.set_initial_max_streams_uni(100)

    Logger.info("Config created: verify_peer=false, ALPNs=[hq-interop]")

    # Connect to server
    Logger.info("Attempting to connect...")

    case Quichex.Connection.connect(
      host: "127.0.0.1",
      port: 4433,
      config: config
    ) do
      {:ok, conn_pid} ->
        Logger.info("Connection process started: #{inspect(conn_pid)}")

        # Wait for connection to be established
        Logger.info("Waiting for handshake to complete...")

        case Quichex.Connection.wait_connected(conn_pid, timeout: 10000) do
          :ok ->
            Logger.info("✓ Connection established!")

            # Get connection info
            {:ok, info} = Quichex.Connection.info(conn_pid)
            Logger.info("Connection info: #{inspect(info)}")

            # Try to open a stream
            Logger.info("Opening bidirectional stream...")
            case Quichex.Connection.open_stream(conn_pid, :bidirectional) do
              {:ok, stream_id} ->
                Logger.info("✓ Stream #{stream_id} opened")

                # Send some data
                Logger.info("Sending data on stream #{stream_id}...")
                case Quichex.Connection.stream_send(conn_pid, stream_id, "GET /\r\n", fin: true) do
                  :ok ->
                    Logger.info("✓ Data sent")

                    # Flush any pending messages (like :quic_connected)
                    receive do
                      {:quic_connected, ^conn_pid} ->
                        Logger.debug("Flushed :quic_connected message")
                    after
                      0 -> :ok
                    end

                    # Check for messages (active mode should deliver data)
                    Logger.info("Waiting for stream data messages...")

                    receive do
                      {:quic_stream, ^conn_pid, ^stream_id, data} ->
                        Logger.info("✓✓✓ Received :quic_stream message! ✓✓✓")
                        Logger.info("Data (#{byte_size(data)} bytes): #{inspect(data)}")

                        # Wait for FIN
                        receive do
                          {:quic_stream_fin, ^conn_pid, ^stream_id} ->
                            Logger.info("✓ Received :quic_stream_fin message")
                          other ->
                            Logger.info("Received other message: #{inspect(other)}")
                        after
                          1000 ->
                            Logger.warning("Timeout waiting for FIN")
                        end

                      other ->
                        Logger.info("Received unexpected message: #{inspect(other)}")
                    after
                      2000 ->
                        Logger.error("✗ Timeout - no :quic_stream message received")

                        # Fall back to manual check
                        Logger.info("Falling back to manual stream check...")
                        case Quichex.Connection.readable_streams(conn_pid) do
                          {:ok, streams} ->
                            Logger.info("Readable streams: #{inspect(streams)}")
                          {:error, reason} ->
                            Logger.error("Failed to get readable streams: #{inspect(reason)}")
                        end
                    end

                  {:error, reason} ->
                    Logger.error("✗ Failed to send data: #{inspect(reason)}")
                end

              {:error, reason} ->
                Logger.error("✗ Failed to open stream: #{inspect(reason)}")
            end

            # Close connection
            Logger.info("Closing connection...")
            :ok = Quichex.Connection.close(conn_pid)
            Logger.info("✓ Connection closed")

          {:error, :connection_closed} ->
            Logger.error("✗ Connection closed during handshake")

          {:error, reason} ->
            Logger.error("✗ Failed to establish connection: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("✗ Failed to start connection: #{inspect(reason)}")
    end

    Logger.info("Test complete")
  end
end

ManualServerTest.run()
