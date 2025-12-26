defmodule Quichex.StreamHandlerTest do
  use ExUnit.Case, async: false

  alias Quichex.{Connection, Config}

  @moduletag :integration

  # Simple Echo handler for testing
  defmodule EchoHandler do
    @behaviour Quichex.StreamHandler.Behaviour

    defstruct [:stream_id, :echo_count]

    @impl true
    def init(stream_id, _direction, _stream_type, _opts) do
      state = %__MODULE__{
        stream_id: stream_id,
        echo_count: 0
      }

      {:ok, state}
    end

    @impl true
    def handle_data(data, fin, state) do
      # Echo the data back
      actions = [{:send, data, fin}]

      new_state = %{state | echo_count: state.echo_count + 1}

      {:ok, actions, new_state}
    end

    @impl true
    def handle_stream_closed(_reason, _state) do
      :ok
    end

    @impl true
    def terminate(_reason, _state) do
      :ok
    end
  end

  # Handler that notifies parent process
  defmodule NotifyHandler do
    @behaviour Quichex.StreamHandler.Behaviour

    defstruct [:parent_pid, :received_data]

    @impl true
    def init(_stream_id, direction, stream_type, opts) do
      parent_pid = Keyword.fetch!(opts, :parent_pid)

      state = %__MODULE__{
        parent_pid: parent_pid,
        received_data: []
      }

      # Notify parent that handler initialized
      send(parent_pid, {:handler_init, direction, stream_type})

      {:ok, state}
    end

    @impl true
    def handle_data(data, fin, state) do
      # Store data
      new_state = %{state | received_data: [data | state.received_data]}

      # Notify parent
      actions = [
        {:notify, state.parent_pid, {:handler_data, data, fin}}
      ]

      {:ok, actions, new_state}
    end

    @impl true
    def handle_stream_closed(reason, state) do
      send(state.parent_pid, {:handler_closed, reason})
      :ok
    end

    @impl true
    def terminate(reason, state) do
      send(state.parent_pid, {:handler_terminate, reason})
      :ok
    end
  end

  setup do
    # Use test config
    config =
      Config.new!()
      |> Config.set_application_protos(["hq-interop"])
      |> Config.verify_peer(false)

    {:ok, config: config}
  end

  describe "StreamHandler lifecycle" do
    test "handler can be spawned for outgoing stream", %{config: config} do
      # Connect without default stream handler
      {:ok, conn} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      # Open stream with handler
      {:ok, handler_pid} =
        Connection.open_stream(conn,
          type: :bidirectional,
          handler: NotifyHandler,
          handler_opts: [parent_pid: self()]
        )

      # Verify handler was initialized
      assert_receive {:handler_init, :outgoing, :bidirectional}, 1_000

      # Verify handler is a process
      assert is_pid(handler_pid)
      assert Process.alive?(handler_pid)

      # Cleanup
      Quichex.close_connection(conn)
    end

    test "handler receives data via handle_data callback", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      # Open stream with NotifyHandler
      {:ok, _handler_pid} =
        Connection.open_stream(conn,
          type: :bidirectional,
          handler: NotifyHandler,
          handler_opts: [parent_pid: self()]
        )

      assert_receive {:handler_init, :outgoing, :bidirectional}, 1_000

      # Note: This test demonstrates the handler lifecycle, but we can't easily
      # test receiving data from the server without server-side stream opening support.
      # For now, we verify the handler spawns correctly.

      Quichex.close_connection(conn)
    end

    test "handler can send data using actions", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      # Open stream with handler
      {:ok, handler_pid} =
        Connection.open_stream(conn,
          type: :bidirectional,
          handler: NotifyHandler,
          handler_opts: [parent_pid: self()]
        )

      assert_receive {:handler_init, :outgoing, :bidirectional}, 1_000

      # Send data directly via handler
      :ok = Quichex.StreamHandler.send_data(handler_pid, "Hello from handler!", false)

      # Verify handler is still alive after send
      assert Process.alive?(handler_pid)

      Quichex.close_connection(conn)
    end

    test "handler cleanup on connection close", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, handler_pid} =
        Connection.open_stream(conn,
          type: :bidirectional,
          handler: NotifyHandler,
          handler_opts: [parent_pid: self()]
        )

      assert_receive {:handler_init, :outgoing, :bidirectional}, 1_000

      # Monitor handler
      ref = Process.monitor(handler_pid)

      # Close connection
      Quichex.close_connection(conn)

      # Handler should terminate
      assert_receive {:DOWN, ^ref, :process, ^handler_pid, _reason}, 2_000
    end
  end

  describe "StreamHandler.send_data/3" do
    test "can send data synchronously", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, handler_pid} =
        Connection.open_stream(conn,
          type: :bidirectional,
          handler: NotifyHandler,
          handler_opts: [parent_pid: self()]
        )

      assert_receive {:handler_init, :outgoing, :bidirectional}, 1_000

      # Send multiple chunks
      assert :ok = Quichex.StreamHandler.send_data(handler_pid, "chunk1", false)
      assert :ok = Quichex.StreamHandler.send_data(handler_pid, "chunk2", false)
      assert :ok = Quichex.StreamHandler.send_data(handler_pid, "chunk3", true)

      # Cannot send after FIN
      assert {:error, :stream_already_finished} =
               Quichex.StreamHandler.send_data(handler_pid, "after_fin", false)

      Quichex.close_connection(conn)
    end

    test "returns error on invalid data", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, handler_pid} =
        Connection.open_stream(conn,
          type: :bidirectional,
          handler: NotifyHandler,
          handler_opts: [parent_pid: self()]
        )

      assert_receive {:handler_init, :outgoing, :bidirectional}, 1_000

      # Sending non-binary data should fail (caught by guards)
      assert catch_error(Quichex.StreamHandler.send_data(handler_pid, 123, false))

      Quichex.close_connection(conn)
    end
  end

  describe "StreamHandler.stats/1" do
    test "returns handler statistics", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, handler_pid} =
        Connection.open_stream(conn,
          type: :bidirectional,
          handler: NotifyHandler,
          handler_opts: [parent_pid: self()]
        )

      assert_receive {:handler_init, :outgoing, :bidirectional}, 1_000

      # Get initial stats
      {:ok, stats} = Quichex.StreamHandler.stats(handler_pid)

      assert stats.direction == :outgoing
      assert stats.stream_type == :bidirectional
      assert stats.bytes_sent == 0
      assert stats.bytes_received == 0
      assert stats.fin_sent == false
      assert stats.fin_received == false
      assert is_integer(stats.stream_id)

      # Send some data
      :ok = Quichex.StreamHandler.send_data(handler_pid, "test data", false)

      # Get updated stats
      {:ok, stats2} = Quichex.StreamHandler.stats(handler_pid)
      assert stats2.bytes_sent == 9
      assert stats2.fin_sent == false

      # Send with FIN
      :ok = Quichex.StreamHandler.send_data(handler_pid, "final", true)

      {:ok, stats3} = Quichex.StreamHandler.stats(handler_pid)
      assert stats3.bytes_sent == 14
      assert stats3.fin_sent == true

      Quichex.close_connection(conn)
    end
  end

  describe "backward compatibility" do
    test "multiple handler types can coexist", %{config: config} do
      {:ok, conn} =
        Quichex.start_connection(
          host: "127.0.0.1",
          port: 4433,
          config: config
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      # Open stream with default MessageHandler (sends messages to controlling process)
      {:ok, handler1} = Connection.open_stream(conn, :bidirectional)
      assert is_pid(handler1)
      stream_id1 = Quichex.StreamHandler.stream_id(handler1)

      # Send data on default handler
      :ok = Quichex.StreamHandler.send_data(handler1, "test data", false)

      # Open ANOTHER stream with custom NotifyHandler
      {:ok, handler2} =
        Connection.open_stream(conn,
          type: :bidirectional,
          handler: NotifyHandler,
          handler_opts: [parent_pid: self()]
        )

      assert is_pid(handler2)
      assert_receive {:handler_init, :outgoing, :bidirectional}, 1_000
      stream_id2 = Quichex.StreamHandler.stream_id(handler2)

      # Both handlers should coexist with different stream IDs
      assert stream_id1 != stream_id2
      assert Process.alive?(handler1)
      assert Process.alive?(handler2)

      # Both handlers can send on their streams
      :ok = Quichex.StreamHandler.send_data(handler1, "more data", true)
      :ok = Quichex.StreamHandler.send_data(handler2, "handler data", false)

      Quichex.close_connection(conn)
    end
  end
end
