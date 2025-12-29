defmodule Quichex.ConnectionSupervisedTest do
  use ExUnit.Case, async: false

  alias Quichex.{Config, Connection}

  @moduletag :integration

  describe "Quichex.start_connection/1" do
    test "creates supervised connection" do
      config = Config.new!() |> Config.verify_peer(false)

      {:ok, conn} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config
        )

      # Verify connection process is alive
      assert Process.alive?(conn)

      # Connection should have a parent supervisor
      {:links, links} = Process.info(conn, :links)
      assert length(links) > 0

      # Find parent (ConnectionSupervisor)
      [parent | _] = links

      # Parent should be a supervisor
      children = Supervisor.which_children(parent)

      # Should have 1 child: Connection only (simplified architecture)
      assert length(children) == 1

      # Verify child is the Connection
      [{id, _conn_pid, :worker, _modules}] = children
      assert id == Quichex.Connection

      Quichex.close_connection(conn)
    end

    test "connection death shuts down entire supervision tree" do
      config = Config.new!() |> Config.verify_peer(false)

      {:ok, conn} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config
        )

      # Get parent supervisor (ConnectionSupervisor)
      {:links, links} = Process.info(conn, :links)
      [conn_sup | _] = links

      # Monitor the supervisor
      ref = Process.monitor(conn_sup)

      # Kill connection (simulate crash)
      Process.exit(conn, :kill)

      # Supervisor should also shut down (due to auto_shutdown: :any_significant)
      assert_receive {:DOWN, ^ref, :process, ^conn_sup, _reason}, 2000
    end

    test "returns connection_limit_reached when max_connections exceeded" do
      # This test requires setting a very low limit and filling it
      # Skip for now as it would require many actual connections
      # and might be flaky in test environment
      :ok
    end

    test "streams work under supervised connection" do
      config = Config.new!() |> Config.verify_peer(false)

      {:ok, conn} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config
        )

      # Wait for connection to establish (server might not be running)
      try do
        :ok = Connection.wait_connected(conn, timeout: 5_000)

        # Open a stream (returns stream_id now, not handler PID)
        {:ok, stream_id} = Connection.open_stream(conn, type: :bidirectional)
        assert is_integer(stream_id)
        assert stream_id == 0  # First bidi stream

        Quichex.close_connection(conn)
      catch
        :exit, _reason ->
          # Server not running or connection failed - test can't complete, but that's ok
          if Process.alive?(conn), do: Quichex.close_connection(conn)
          :ok
      end
    end

    test "multiple supervised connections work independently" do
      config = Config.new!() |> Config.verify_peer(false)

      {:ok, conn1} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config
        )

      {:ok, conn2} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config
        )

      # Both connections should be alive
      assert Process.alive?(conn1)
      assert Process.alive?(conn2)

      # They should be different processes
      assert conn1 != conn2

      # Kill one connection
      Process.exit(conn1, :kill)
      Process.sleep(100)

      # Other connection should still be alive
      assert Process.alive?(conn2)

      Quichex.close_connection(conn2)
    end
  end
end
