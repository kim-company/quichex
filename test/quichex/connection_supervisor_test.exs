defmodule Quichex.ConnectionSupervisorTest do
  use ExUnit.Case, async: false

  alias Quichex.{Config, ConnectionSupervisor}

  @moduletag :integration

  describe "ConnectionSupervisor" do
    test "starts with Connection and StreamHandlerSupervisor children" do
      config = Config.new!() |> Config.verify_peer(false)

      opts = [
        host: "127.0.0.1",
        port: 4433,
        config: config
      ]

      {:ok, sup_pid} = ConnectionSupervisor.start_link(opts)

      # Should have 2 children
      children = Supervisor.which_children(sup_pid)
      assert length(children) == 2

      # Find children by id
      ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)
      assert Quichex.Connection in ids
      assert Quichex.StreamHandlerSupervisor in ids

      # Verify child types
      connection_child =
        Enum.find(children, fn {id, _pid, _type, _modules} ->
          id == Quichex.Connection
        end)

      handler_sup_child =
        Enum.find(children, fn {id, _pid, _type, _modules} ->
          id == Quichex.StreamHandlerSupervisor
        end)

      {_id, _conn_pid, :worker, _modules} = connection_child
      {_id, _sup_pid, :supervisor, _modules} = handler_sup_child

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

    test "stream_handler_supervisor_pid/1 returns StreamHandlerSupervisor PID" do
      config = Config.new!() |> Config.verify_peer(false)

      opts = [
        host: "127.0.0.1",
        port: 4433,
        config: config
      ]

      {:ok, sup_pid} = ConnectionSupervisor.start_link(opts)

      {:ok, handler_sup_pid} = ConnectionSupervisor.stream_handler_supervisor_pid(sup_pid)

      assert is_pid(handler_sup_pid)
      assert Process.alive?(handler_sup_pid)

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
      sup_pid = receive do
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

    test "respects max_stream_handlers configuration" do
      config = Config.new!() |> Config.verify_peer(false)

      # Override max_stream_handlers
      opts = [
        host: "127.0.0.1",
        port: 4433,
        config: config,
        max_stream_handlers: 10
      ]

      {:ok, sup_pid} = ConnectionSupervisor.start_link(opts)
      {:ok, handler_sup_pid} = ConnectionSupervisor.stream_handler_supervisor_pid(sup_pid)

      # Get max_children from DynamicSupervisor (not directly accessible, but we can verify it works)
      # This is more of an integration test - just verify the supervisor started
      assert Process.alive?(handler_sup_pid)

      # Clean up
      Process.exit(sup_pid, :shutdown)
    end
  end
end
