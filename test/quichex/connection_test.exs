defmodule Quichex.ConnectionTest do
  use ExUnit.Case, async: true

  alias Quichex.{Config, Connection}
  alias Quichex.Test.NoOpHandler

  describe "Connection.start_link/1" do
    test "creates a connection with valid config" do
      config =
        Config.new!()
        |> Config.set_application_protos(["test"])
        |> Config.verify_peer(false)

      # This will fail to connect since there's no server, but should create the process
      # Using start_link_supervised! to bypass ConnectionRegistry for unit testing
      pid = start_link_supervised!({Connection, [host: "127.0.0.1", port: 9999, config: config, handler: NoOpHandler]})
      assert Process.alive?(pid)

      # No cleanup needed - ExUnit supervisor handles it
    end

    test "requires host option" do
      config = Config.new!()

      # Connection.start_link should fail when required option missing
      assert_raise RuntimeError, ~r/failed to start child/, fn ->
        start_link_supervised!({Connection, [port: 4433, config: config]})
      end
    end

    test "requires port option" do
      config = Config.new!()

      assert_raise RuntimeError, ~r/failed to start child/, fn ->
        start_link_supervised!({Connection, [host: "localhost", config: config]})
      end
    end

    test "requires config option" do
      assert_raise RuntimeError, ~r/failed to start child/, fn ->
        start_link_supervised!({Connection, [host: "localhost", port: 4433]})
      end
    end
  end

  describe "is_established?/1" do
    test "returns false for new connection" do
      config =
        Config.new!()
        |> Config.set_application_protos(["test"])

      pid = start_link_supervised!({Connection, [host: "127.0.0.1", port: 9999, config: config, handler: NoOpHandler]})

      # Without a server, connection won't establish
      refute Connection.is_established?(pid)
    end
  end

  describe "is_closed?/1" do
    test "returns false for active connection" do
      config = Config.new!()
      pid = start_link_supervised!({Connection, [host: "127.0.0.1", port: 9999, config: config, handler: NoOpHandler]})

      refute Connection.is_closed?(pid)

      # No cleanup needed - ExUnit supervisor handles it
    end

    test "returns true after closing" do
      config = Config.new!()
      pid = start_link_supervised!({Connection, [host: "127.0.0.1", port: 9999, config: config, handler: NoOpHandler]})

      :ok = Connection.close(pid)

      assert Connection.is_closed?(pid)
    end
  end

  describe "close/2" do
    test "closes the connection with default options" do
      config = Config.new!()
      pid = start_link_supervised!({Connection, [host: "127.0.0.1", port: 9999, config: config, handler: NoOpHandler]})

      assert :ok = Connection.close(pid)
    end

    test "closes the connection with custom error code" do
      config = Config.new!()
      pid = start_link_supervised!({Connection, [host: "127.0.0.1", port: 9999, config: config, handler: NoOpHandler]})

      assert :ok = Connection.close(pid, error_code: 42, reason: "test close")
    end
  end

  describe "info/1" do
    test "returns connection information" do
      config = Config.new!()
      pid = start_link_supervised!({Connection, [host: "127.0.0.1", port: 9999, config: config, handler: NoOpHandler]})

      assert {:ok, info} = Connection.info(pid)
      assert is_map(info)
      assert info.server_name == "127.0.0.1"
      assert info.peer_address == {{127, 0, 0, 1}, 9999}
      assert is_tuple(info.local_address)
      refute info.is_established
      refute info.is_closed

      # No cleanup needed - ExUnit supervisor handles it
    end
  end

  describe "hostname resolution" do
    test "resolves localhost" do
      config =
        Config.new!()
        |> Config.set_application_protos(["test"])

      pid = start_link_supervised!({Connection, [host: "localhost", port: 9999, config: config, handler: NoOpHandler]})

      {:ok, info} = Connection.info(pid)
      assert info.server_name == "localhost"
      # Should resolve to either IPv4 or IPv6 loopback
      assert is_tuple(elem(info.peer_address, 0))

      # No cleanup needed - ExUnit supervisor handles it
    end
  end

  describe "connection lifecycle" do
    test "sends packets on initialization" do
      config =
        Config.new!()
        |> Config.set_application_protos(["test"])
        |> Config.set_max_idle_timeout(1000)

      pid = start_link_supervised!({Connection, [host: "127.0.0.1", port: 9999, config: config, handler: NoOpHandler]})

      # Connection should be alive
      assert Process.alive?(pid)

      # Wait a bit for initial packets
      Process.sleep(100)

      # Connection should still be alive (timeout not reached)
      assert Process.alive?(pid)

      # No cleanup needed - ExUnit supervisor handles it
    end
  end

  # NOTE: The following test requires internet connectivity and connects to a real QUIC server.
  # Tagged as :external so it can be excluded from local testing with: mix test --exclude external
  @tag :external
  test "connects to cloudflare-quic.com with proper TLS handshake" do
    # Create base config - use "h3" protocol which cloudflare-quic.com supports
    base_config = Config.new!()
      |> Config.set_application_protos(["h3"])
      |> Config.verify_peer(false)
      |> Config.set_max_idle_timeout(5000)
      # Critical: Set UDP payload sizes for proper TLS handshake
      |> Config.set_max_recv_udp_payload_size(1350)
      |> Config.set_max_send_udp_payload_size(1350)
      |> Config.set_disable_active_migration(true)
      # Critical: Set flow control limits (default to 0 in quiche)
      |> Config.set_initial_max_data(10_000_000)
      |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
      |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)
      |> Config.set_initial_max_stream_data_uni(1_000_000)
      |> Config.set_initial_max_streams_bidi(100)
      |> Config.set_initial_max_streams_uni(100)

    # Critical: Load system CA certificates (required for TLS even with verify_peer(false))
    config = case Config.load_system_ca_certs(base_config) do
      {:ok, cfg} -> cfg
      {:error, reason} ->
        IO.puts("Warning: Could not load system CA certs: #{reason}")
        base_config
    end

    {:ok, pid} = Quichex.start_connection(
      host: "cloudflare-quic.com",
      port: 443,
      config: config
    )

    # Wait for handshake to complete (should succeed with UDP payload sizes configured)
    assert :ok = Connection.wait_connected(pid, timeout: 10_000)

    # Connection should be established
    assert Connection.is_established?(pid)

    {:ok, info} = Connection.info(pid)
    assert info.is_established

    Quichex.close_connection(pid)
  end
end
