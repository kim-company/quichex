# Minimal test to debug data reception with notification-based API
alias Quichex.{Config, Connection}

defmodule Helper do
  def flush_messages() do
    receive do
      msg ->
        IO.inspect(msg, label: "Message")
        flush_messages()
    after
      0 -> IO.puts("(no more messages)")
    end
  end
end

config = Config.new!()
  |> Config.set_application_protos(["hq-interop"])
  |> Config.verify_peer(false)
  |> Config.set_initial_max_data(10_000_000)
  |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
  |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)

IO.puts("Starting connection...")
{:ok, conn} = Quichex.start_connection(
  host: "127.0.0.1",
  port: 4433,
  config: config
)

IO.puts("Waiting for connection...")
:ok = Connection.wait_connected(conn, timeout: 5_000)
IO.puts("✅ Connected!")

# Open stream 0 (don't use it - just to get to stream 4)
{:ok, stream0} = Connection.open_stream(conn, type: :bidirectional)
IO.puts("Opened stream #{stream0} (dummy)")

# Open stream 4 (this is what quiche HTTP/0.9 client uses)
{:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)
IO.puts("✅ Stream opened: stream_id=#{stream_id}")

# Send HTTP/0.9 request
{:ok, bytes} = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)
IO.puts("✅ Request sent on stream #{stream_id} (#{bytes} bytes)")

# Wait and keep showing messages as they arrive
IO.puts("\nWaiting 5 seconds and showing all messages...")

Enum.each(1..10, fn i ->
  Process.sleep(500)

  receive do
    {:quic_stream_readable, ^conn, readable_stream_id} ->
      IO.puts("[#{i * 500}ms] Stream #{readable_stream_id} is readable!")

      # Read the data
      case Connection.stream_recv(conn, readable_stream_id) do
        {:ok, {data, fin}} ->
          IO.puts("  Read #{byte_size(data)} bytes (fin=#{fin})")
          IO.puts("  Data: #{inspect(data)}")
        {:error, reason} ->
          IO.puts("  Failed to read: #{inspect(reason)}")
      end

    msg ->
      IO.puts("[#{i * 500}ms] Got message: #{inspect(msg)}")
  after
    0 -> :ok
  end
end)

# Flush any remaining messages
IO.puts("\nRemaining mailbox contents:")
Helper.flush_messages()

Quichex.close_connection(conn)
IO.puts("\n✅ Done")
