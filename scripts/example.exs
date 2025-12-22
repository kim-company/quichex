#!/usr/bin/env elixir
#
# Example: Connect to local quiche-server and send/receive data
#
# Prerequisites:
#   1. Build quiche-server:
#      cd ../quiche && cargo build --examples
#
#   2. Create content directory with test file:
#      mkdir -p ../quiche/quiche/examples/root
#      echo '<!DOCTYPE html><html><body><h1>Hello!</h1></body></html>' > ../quiche/quiche/examples/root/index.html
#
#   3. Start quiche-server in another terminal:
#      cd ../quiche/quiche && RUST_LOG=info ../../target/debug/examples/server
#
# Usage:
#   mix run scripts/example.exs

require Logger

Logger.configure(level: :info)

Logger.info("=== Quichex Example: Local quiche-server ===\n")

# Create QUIC config
config =
  Quichex.Config.new!()
  |> Quichex.Config.set_application_protos(["hq-interop"])
  |> Quichex.Config.verify_peer(false)
  |> Quichex.Config.set_max_idle_timeout(30_000)
  |> Quichex.Config.set_initial_max_streams_bidi(100)
  |> Quichex.Config.set_initial_max_data(10_000_000)
  |> Quichex.Config.set_initial_max_stream_data_bidi_local(1_000_000)
  |> Quichex.Config.set_initial_max_stream_data_bidi_remote(1_000_000)

Logger.info("1. Connecting to 127.0.0.1:4433...")
Logger.info("   (Make sure quiche-server is running!)")

# Connect
case Quichex.Connection.connect(
       host: "127.0.0.1",
       port: 4433,
       config: config
     ) do
  {:ok, conn} ->
    Logger.info("   ✓ Connection process started\n")

    # Wait for handshake to complete
    Logger.info("2. Waiting for QUIC handshake to complete...")

    case Quichex.Connection.wait_connected(conn, timeout: 10_000) do
      :ok ->
        Logger.info("   ✓ Handshake complete!\n")

        # Flush any pending :quic_connected messages (sent asynchronously)
        receive do
          {:quic_connected, ^conn} -> :ok
        after
          0 -> :ok
        end

        # Get connection info
        {:ok, info} = Quichex.Connection.info(conn)

        Logger.info("Connection details:")
        Logger.info("  - Server: #{info.server_name}")
        Logger.info("  - Local:  #{inspect(info.local_address)}")
        Logger.info("  - Remote: #{inspect(info.peer_address)}")
        Logger.info("  - Established: #{info.is_established}")
        Logger.info("")

        # Open a stream
        Logger.info("3. Opening bidirectional stream...")

        case Quichex.Connection.open_stream(conn, :bidirectional) do
          {:ok, stream_id} ->
            Logger.info("   ✓ Stream #{stream_id} opened\n")

            # Send HTTP/0.9 GET request (hq-interop protocol)
            Logger.info("4. Sending HTTP/0.9 GET request...")
            request = "GET /index.html\r\n"

            case Quichex.Connection.stream_send(conn, stream_id, request, fin: true) do
              :ok ->
                Logger.info("   ✓ Request sent (#{byte_size(request)} bytes)\n")

                # Wait for response (active mode sends messages to controlling process)
                Logger.info("5. Waiting for response...")
                Logger.info("   (Active mode: messages sent automatically)\n")

                receive do
                  {:quic_stream, ^conn, ^stream_id, data} ->
                    Logger.info("   ✓ Received response!")
                    Logger.info("   Response (#{byte_size(data)} bytes):")

                    # Show first 200 chars of response
                    preview =
                      if byte_size(data) > 200 do
                        binary_part(data, 0, 200) <> "..."
                      else
                        data
                      end

                    Logger.info("   " <> String.replace(preview, "\n", "\n   "))
                    Logger.info("")

                    # Wait for stream to finish
                    receive do
                      {:quic_stream_fin, ^conn, ^stream_id} ->
                        Logger.info("   ✓ Stream FIN received")
                    after
                      2000 ->
                        Logger.info("   (No FIN received yet, continuing...)")
                    end

                  other ->
                    Logger.warning("   Unexpected message: #{inspect(other)}")
                after
                  5000 ->
                    Logger.error("   ✗ Timeout waiting for response")
                    Logger.error("   Is quiche-server running and responding?")
                end

              {:error, reason} ->
                Logger.error("   ✗ Failed to send request: #{inspect(reason)}")
            end

          {:error, reason} ->
            Logger.error("   ✗ Failed to open stream: #{inspect(reason)}")
        end

        # Close connection
        Logger.info("\n6. Closing connection...")
        :ok = Quichex.Connection.close(conn)
        Logger.info("   ✓ Connection closed")

      {:error, reason} ->
        Logger.error("   ✗ Handshake failed: #{inspect(reason)}")
        Logger.error("   Make sure quiche-server is running!")
        Quichex.Connection.close(conn)
    end

  {:error, reason} ->
    Logger.error("   ✗ Failed to start connection: #{inspect(reason)}")
end

Logger.info("\n=== Example Complete ===")
Logger.info("")
Logger.info("If you saw a timeout, make sure quiche-server is running:")
Logger.info("  cd ../quiche/quiche")
Logger.info("  RUST_LOG=info ../../target/debug/examples/server")
