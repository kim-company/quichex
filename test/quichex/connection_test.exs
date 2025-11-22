defmodule Quichex.ConnectionTest do
  use ExUnit.Case, async: false

  alias Quichex.{Config, Connection}

  describe "connect/1" do
    test "creates a connection with valid config" do
      config =
        Config.new!()
        |> Config.set_application_protos(["test"])
        |> Config.verify_peer(false)

      # This will fail to connect since there's no server, but should create the process
      assert {:ok, pid} = Connection.connect(host: "127.0.0.1", port: 9999, config: config)
      assert Process.alive?(pid)

      # Clean up
      Connection.close(pid)
    end

    test "requires host option" do
      config = Config.new!()

      # GenServer.start_link will return {:error, reason} when init fails
      Process.flag(:trap_exit, true)
      assert {:error, {:connection_error, %KeyError{key: :host}}} =
        Connection.connect(port: 4433, config: config)
    end

    test "requires port option" do
      config = Config.new!()

      Process.flag(:trap_exit, true)
      assert {:error, {:connection_error, %KeyError{key: :port}}} =
        Connection.connect(host: "localhost", config: config)
    end

    test "requires config option" do
      Process.flag(:trap_exit, true)
      assert {:error, {:connection_error, %KeyError{key: :config}}} =
        Connection.connect(host: "localhost", port: 4433)
    end
  end

  describe "is_established?/1" do
    test "returns false for new connection" do
      config =
        Config.new!()
        |> Config.set_application_protos(["test"])

      {:ok, pid} = Connection.connect(host: "127.0.0.1", port: 9999, config: config)

      # Without a server, connection won't establish
      refute Connection.is_established?(pid)

      Connection.close(pid)
    end
  end

  describe "is_closed?/1" do
    test "returns false for active connection" do
      config = Config.new!()
      {:ok, pid} = Connection.connect(host: "127.0.0.1", port: 9999, config: config)

      refute Connection.is_closed?(pid)

      Connection.close(pid)
    end

    test "returns true after closing" do
      config = Config.new!()
      {:ok, pid} = Connection.connect(host: "127.0.0.1", port: 9999, config: config)

      :ok = Connection.close(pid)

      assert Connection.is_closed?(pid)
    end
  end

  describe "close/2" do
    test "closes the connection with default options" do
      config = Config.new!()
      {:ok, pid} = Connection.connect(host: "127.0.0.1", port: 9999, config: config)

      assert :ok = Connection.close(pid)
    end

    test "closes the connection with custom error code" do
      config = Config.new!()
      {:ok, pid} = Connection.connect(host: "127.0.0.1", port: 9999, config: config)

      assert :ok = Connection.close(pid, error_code: 42, reason: "test close")
    end
  end

  describe "info/1" do
    test "returns connection information" do
      config = Config.new!()
      {:ok, pid} = Connection.connect(host: "127.0.0.1", port: 9999, config: config)

      assert {:ok, info} = Connection.info(pid)
      assert is_map(info)
      assert info.server_name == "127.0.0.1"
      assert info.peer_address == {{127, 0, 0, 1}, 9999}
      assert is_tuple(info.local_address)
      refute info.is_established
      refute info.is_closed

      Connection.close(pid)
    end
  end

  describe "hostname resolution" do
    test "resolves localhost" do
      config =
        Config.new!()
        |> Config.set_application_protos(["test"])

      {:ok, pid} = Connection.connect(host: "localhost", port: 9999, config: config)

      {:ok, info} = Connection.info(pid)
      assert info.server_name == "localhost"
      # Should resolve to either IPv4 or IPv6 loopback
      assert is_tuple(elem(info.peer_address, 0))

      Connection.close(pid)
    end
  end

  describe "connection lifecycle" do
    test "sends packets on initialization" do
      config =
        Config.new!()
        |> Config.set_application_protos(["test"])
        |> Config.set_max_idle_timeout(1000)

      {:ok, pid} = Connection.connect(host: "127.0.0.1", port: 9999, config: config)

      # Connection should be alive
      assert Process.alive?(pid)

      # Wait a bit for initial packets
      Process.sleep(100)

      # Connection should still be alive (timeout not reached)
      assert Process.alive?(pid)

      Connection.close(pid)
    end
  end

  # NOTE: The following test requires a running QUIC server.
  # To test against cloudflare-quic.com (public test server):
  #
  # @tag :external
  # test "connects to cloudflare-quic.com" do
  #   config =
  #     Config.new!()
  #     |> Config.set_application_protos(["hq-interop"])
  #     |> Config.verify_peer(false)
  #     |> Config.set_max_idle_timeout(5000)
  #
  #   {:ok, pid} = Connection.connect(
  #     host: "cloudflare-quic.com",
  #     port: 443,
  #     config: config
  #   )
  #
  #   # Wait for handshake
  #   assert :ok = Connection.wait_connected(pid, timeout: 10_000)
  #
  #   # Connection should be established
  #   assert Connection.is_established?(pid)
  #
  #   {:ok, info} = Connection.info(pid)
  #   assert info.is_established
  #
  #   Connection.close(pid)
  # end
end
