# Test HTTP/0.9 request to local quiche-server
# This verifies we can:
# 1. Establish connection
# 2. Send data
# 3. Receive data
# 4. Keep connection open

alias Quichex.{Config, Connection}

defmodule HTTPTest do
  def receive_all_data(conn, stream_id, acc, timeout) do
    receive do
      {:quic_stream_readable, ^conn, ^stream_id} ->
        # Stream readable, read data
        case Connection.stream_recv(conn, stream_id) do
          {:ok, {data, fin}} ->
            new_acc = [acc, data]
            if fin do
              # Stream closed, return accumulated data
              new_acc
            else
              # Keep receiving
              receive_all_data(conn, stream_id, new_acc, 1000)
            end

          {:error, _reason} ->
            # Error reading, return what we have
            acc
        end

      other ->
        IO.puts("Unexpected message: #{inspect(other)}")
        receive_all_data(conn, stream_id, acc, timeout)
    after
      timeout ->
        # Timeout, return what we have
        acc
    end
  end
end

# Create config with proper flow control limits
config = Config.new!()
  |> Config.set_application_protos(["hq-interop"])
  |> Config.verify_peer(false)
  |> Config.set_initial_max_data(10_000_000)
  |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
  |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)

IO.puts("Connecting to localhost:4433...")

# Connect (supervised, socket always active)
{:ok, conn} = Quichex.start_connection(
  host: "127.0.0.1",
  port: 4433,
  config: config
)

IO.puts("Connection started: #{inspect(conn)}")

# Wait for connection to establish
case Connection.wait_connected(conn, timeout: 5_000) do
  :ok ->
    IO.puts("✅ Connection established!")

    # Open a bidirectional stream
    IO.puts("Opening stream...")
    {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)
    IO.puts("✅ Stream opened: stream_id=#{stream_id}")

    # Send HTTP/0.9 request
    request = "GET /index.html\r\n"
    IO.puts("Sending request: #{inspect(request)}")
    {:ok, bytes_written} = Connection.stream_send(conn, stream_id, request, fin: true)
    IO.puts("✅ Request sent (#{bytes_written} bytes)")

    # Receive response
    IO.puts("Waiting for response...")
    IO.puts("Controlling process PID: #{inspect(self())}")

    # Collect all data
    data_chunks = HTTPTest.receive_all_data(conn, stream_id, [], 5_000)

    if data_chunks == [] do
      IO.puts("❌ No data received")

      # Check for any unexpected messages
      IO.puts("\nChecking for unexpected messages:")
      receive do
        msg ->
          IO.puts("Got unexpected message: #{inspect(msg)}")
      after
        100 -> IO.puts("No unexpected messages")
      end
    else
      full_data = IO.iodata_to_binary(data_chunks)
      IO.puts("✅ Received #{byte_size(full_data)} bytes total:")
      IO.puts("---")
      IO.write(full_data)
      IO.puts("\n---")
    end

    # Keep connection open for a bit
    IO.puts("Keeping connection open for 2 seconds...")
    Process.sleep(2000)

    # Close connection
    IO.puts("Closing connection...")
    Quichex.close_connection(conn)
    IO.puts("✅ Connection closed")

  {:error, reason} ->
    IO.puts("❌ Failed to establish connection: #{inspect(reason)}")
    Quichex.close_connection(conn)
end

IO.puts("\n✅ Test complete!")
