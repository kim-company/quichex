#!/usr/bin/env elixir

# Test script to debug TLS connection issues

alias Quichex.Config
alias Quichex.Connection

IO.puts("Creating config with UDP payload sizes...")

config =
  Config.new!()
  |> Config.set_application_protos(["hq-interop"])
  |> Config.verify_peer(false)
  |> Config.set_max_idle_timeout(5000)
  |> Config.set_max_recv_udp_payload_size(1350)
  |> Config.set_max_send_udp_payload_size(1350)
  |> Config.set_disable_active_migration(true)
  |> Config.set_initial_max_data(10_000_000)
  |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
  |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)
  |> Config.set_initial_max_streams_bidi(100)
  |> Config.set_initial_max_streams_uni(100)

IO.puts("Config created successfully!")

IO.puts("\nConnecting to cloudflare-quic.com:443...")

{:ok, pid} = Connection.connect(
  host: "cloudflare-quic.com",
  port: 443,
  config: config
)

IO.puts("Connection process started: #{inspect(pid)}")

# Wait a bit for packets to be exchanged
Process.sleep(2000)

IO.puts("\nChecking connection status...")
established = Connection.is_established?(pid)
IO.puts("Is established? #{established}")

if not established do
  IO.puts("\nWaiting for connection to establish...")
  case Connection.wait_connected(pid, timeout: 10_000) do
    :ok ->
      IO.puts("✅ Connection established!")
      {:ok, info} = Connection.info(pid)
      IO.puts("Connection info: #{inspect(info)}")
    {:error, reason} ->
      IO.puts("❌ Failed to establish: #{inspect(reason)}")
  end
else
  IO.puts("✅ Connection already established!")
  {:ok, info} = Connection.info(pid)
  IO.puts("Connection info: #{inspect(info)}")
end

IO.puts("\nClosing connection...")
Connection.close(pid)
IO.puts("Done!")
