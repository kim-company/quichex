# Test HTTP/0.9 request to local quiche-server
# This verifies we can:
# 1. Establish connection
# 2. Send data
# 3. Receive data
# 4. Keep connection open

alias Quichex.{Config, Connection, StreamHandler}

defmodule HTTPTest do
  def receive_all_data(handler, acc, timeout) do
    receive do
      {:quic_stream, ^handler, data} ->
        # Got data, keep receiving
        receive_all_data(handler, [acc, data], 1000)

      {:quic_stream_fin, ^handler} ->
        # Stream closed, return accumulated data
        acc

      other ->
        IO.puts("Unexpected message: #{inspect(other)}")
        receive_all_data(handler, acc, timeout)
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

# Connect (supervised with active mode)
{:ok, conn} = Quichex.start_connection(
  host: "127.0.0.1",
  port: 4433,
  config: config,
  active: true
)

IO.puts("Connection started: #{inspect(conn)}")

# Wait for connection to establish
case Connection.wait_connected(conn, timeout: 5_000) do
  :ok ->
    IO.puts("✅ Connection established!")

    # Open a bidirectional stream
    IO.puts("Opening stream...")
    {:ok, handler} = Connection.open_stream(conn, :bidirectional)
    IO.puts("✅ Stream opened: #{inspect(handler)}")

    # Send HTTP/0.9 request
    request = "GET /index.html\r\n"
    IO.puts("Sending request: #{inspect(request)}")
    :ok = StreamHandler.send_data(handler, request, true)
    IO.puts("✅ Request sent")

    # Receive response
    IO.puts("Waiting for response...")
    IO.puts("My PID: #{inspect(self())}")
    IO.puts("Handler PID: #{inspect(handler)}")

    # Collect all data
    data_chunks = HTTPTest.receive_all_data(handler, [], 5_000)

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
