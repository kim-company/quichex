defmodule Quichex.ConnectionSupervisorTest do
  use ExUnit.Case, async: false

  alias Quichex.{Config, ConnectionSupervisor}

  @moduletag :integration

  describe "ConnectionSupervisor" do
    test "starts with Connection child" do
      config = Config.new!() |> Config.verify_peer(false)

      opts = [
        host: "127.0.0.1",
        port: 4433,
        config: config
      ]

      {:ok, sup_pid} = ConnectionSupervisor.start_link(opts)

      # Should have 1 child (Connection only)
      children = Supervisor.which_children(sup_pid)
      assert length(children) == 1

      # Verify it's the Connection child
      [{id, conn_pid, :worker, _modules}] = children
      assert id == Quichex.Connection
      assert is_pid(conn_pid)
      assert Process.alive?(conn_pid)

      # Clean up
      Process.exit(sup_pid, :shutdown)
    end

    test "connection_pid/1 returns Connection process PID" do
      config = Config.new!() |> Config.verify_peer(false)

      opts = [
        host: "127.0.0.1",
        port: 4433,
        config: config
      ]

      {:ok, sup_pid} = ConnectionSupervisor.start_link(opts)

      {:ok, conn_pid} = ConnectionSupervisor.connection_pid(sup_pid)

      assert is_pid(conn_pid)
      assert Process.alive?(conn_pid)

      # Clean up
      Process.exit(sup_pid, :shutdown)
    end

    test "shuts down when Connection dies (auto_shutdown: :any_significant)" do
      config = Config.new!() |> Config.verify_peer(false)

      opts = [
        host: "127.0.0.1",
        port: 4433,
        config: config
      ]

      # Spawn a process to start the supervisor so test isn't linked to it
      parent = self()
      spawn(fn ->
        {:ok, sup_pid} = ConnectionSupervisor.start_link(opts)
        send(parent, {:supervisor_started, sup_pid})
        # Keep process alive
        :timer.sleep(:infinity)
      end)

      # Wait for supervisor to start
      sup_pid =
        receive do
          {:supervisor_started, pid} -> pid
        after
          2000 -> raise "Supervisor didn't start"
        end

      {:ok, conn_pid} = ConnectionSupervisor.connection_pid(sup_pid)

      # Monitor supervisor
      ref = Process.monitor(sup_pid)

      # Kill connection (significant child)
      Process.exit(conn_pid, :shutdown)

      # Supervisor should also die due to auto_shutdown: :any_significant
      assert_receive {:DOWN, ^ref, :process, ^sup_pid, _reason}, 2000
    end

    test "passes configuration options to Connection" do
      config =
        Config.new!()
        |> Config.verify_peer(false)
        |> Config.set_initial_max_data(1_000_000)

      opts = [
        host: "127.0.0.1",
        port: 4433,
        config: config,
        stream_recv_buffer_size: 32768
      ]

      {:ok, sup_pid} = ConnectionSupervisor.start_link(opts)
      {:ok, conn_pid} = ConnectionSupervisor.connection_pid(sup_pid)

      # Connection should be alive and configured
      assert Process.alive?(conn_pid)

      # Clean up
      Process.exit(sup_pid, :shutdown)
    end
  end
end
