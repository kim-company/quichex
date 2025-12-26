# Minimal test to debug data reception
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
{:ok, _stream0} = Connection.open_stream(conn, :bidirectional)
IO.puts("Opened stream 0 (dummy)")

# Open stream 4 (this is what quiche HTTP/0.9 client uses)
{:ok, handler} = Connection.open_stream(conn, :bidirectional)
stream_id = Quichex.StreamHandler.stream_id(handler)
IO.puts("✅ Stream opened: #{inspect(handler)}, stream_id=#{stream_id}")

# Send HTTP/0.9 request
:ok = Quichex.StreamHandler.send_data(handler, "GET /index.html\r\n", true)
IO.puts("✅ Request sent on stream #{stream_id}")

# Wait and keep showing messages as they arrive
IO.puts("\nWaiting 5 seconds and showing all messages...")

Enum.each(1..10, fn i ->
  Process.sleep(500)

  receive do
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
