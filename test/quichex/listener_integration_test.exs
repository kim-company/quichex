defmodule Quichex.ListenerIntegrationTest do
  # Cannot run async because all tests share the global ConnectionRegistry
  # and this test creates many concurrent connections which can interfere
  # with other tests running in parallel
  use ExUnit.Case, async: false

  alias Quichex.{Connection, Listener}
  alias Quichex.Test.{EchoHandler, ListenerHelpers}

  describe "listener integration" do
    test "echo test - client sends data, server echoes back" do
      # Start listener with EchoHandler using supervised!/2
      listener_spec =
        ListenerHelpers.listener_spec(
          handler: EchoHandler,
          handler_opts: []
        )

      listener = start_link_supervised!(listener_spec)

      # Get the port the listener is bound to
      assert {:ok, {_ip, port}} = Listener.local_address(listener)
      assert is_integer(port)
      assert port > 0

      # Start a client connection
      assert {:ok, client} =
               ListenerHelpers.start_client(port, handler_opts: [controlling_process: self()])

      # Wait for connection establishment
      assert :ok = ListenerHelpers.wait_for_connection(client, 1_000)

      # Verify we get the connection established notification
      assert_receive {:quic_connected, ^client}, 1_000

      # Open a bidirectional stream
      assert {:ok, stream_id} = Connection.open_stream(client, type: :bidirectional)

      # Send data on the stream
      test_data = "Hello, QUIC!"
      assert {:ok, _bytes} = Connection.stream_send(client, stream_id, test_data, fin: true)

      # Wait for echo response
      assert {:ok, received_data, true} =
               ListenerHelpers.wait_for_stream_data(client, stream_id, 2_000)

      # Verify echoed data matches
      assert received_data == test_data

      # Clean up
      ListenerHelpers.stop_client(client)
    end

    test "listener tracks active connections" do
      # Start listener
      listener_spec =
        ListenerHelpers.listener_spec(
          handler: EchoHandler,
          handler_opts: []
        )

      listener = start_link_supervised!(listener_spec)
      assert {:ok, {_ip, port}} = Listener.local_address(listener)

      # Initially no connections
      assert 0 = Listener.connection_count(listener)

      # Connect first client
      assert {:ok, client1} =
               ListenerHelpers.start_client(port, handler_opts: [controlling_process: self()])
      assert :ok = ListenerHelpers.wait_for_connection(client1, 1_000)

      # Should have 1 connection
      assert 1 = Listener.connection_count(listener)

      # Connect second client
      assert {:ok, client2} =
               ListenerHelpers.start_client(port, handler_opts: [controlling_process: self()])
      assert :ok = ListenerHelpers.wait_for_connection(client2, 1_000)

      # Should have 2 connections
      assert 2 = Listener.connection_count(listener)

      # Close first client
      ListenerHelpers.stop_client(client1)

      # Give time for connection cleanup (closed state has 50ms timeout)
      Process.sleep(150)

      # Should have 1 connection
      assert 1 = Listener.connection_count(listener)

      # Clean up
      ListenerHelpers.stop_client(client2)
    end

    test "multiple streams on single connection" do
      # Start listener
      listener_spec =
        ListenerHelpers.listener_spec(
          handler: EchoHandler,
          handler_opts: []
        )

      listener = start_link_supervised!(listener_spec)
      assert {:ok, {_ip, port}} = Listener.local_address(listener)

      # Connect client
      assert {:ok, client} = ListenerHelpers.start_client(port, handler_opts: [controlling_process: self()])
      assert :ok = ListenerHelpers.wait_for_connection(client, 1_000)

      # Open multiple streams and send data
      num_streams = 5

      stream_data =
        for i <- 1..num_streams do
          {:ok, stream_id} = Connection.open_stream(client, type: :bidirectional)
          data = "Stream #{i} data"
          {:ok, _bytes} = Connection.stream_send(client, stream_id, data, fin: true)
          {stream_id, data}
        end

      # Verify all streams get echoed back
      for {stream_id, expected_data} <- stream_data do
        assert {:ok, received_data, true} =
                 ListenerHelpers.wait_for_stream_data(client, stream_id, 2_000)

        assert received_data == expected_data
      end

      # Clean up
      ListenerHelpers.stop_client(client)
    end

    test "multiple concurrent connections" do
      # Start listener
      listener_spec =
        ListenerHelpers.listener_spec(
          handler: EchoHandler,
          handler_opts: []
        )

      listener = start_link_supervised!(listener_spec)
      assert {:ok, {_ip, port}} = Listener.local_address(listener)

      # Connect multiple clients
      num_clients = 10

      clients =
        for i <- 1..num_clients do
          {:ok, client} =
            ListenerHelpers.start_client(port, handler_opts: [controlling_process: self()])
          :ok = ListenerHelpers.wait_for_connection(client, 1_000)
          {i, client}
        end

      # Verify connection count
      assert ^num_clients = Listener.connection_count(listener)

      # Each client sends unique data
      for {i, client} <- clients do
        {:ok, stream_id} = Connection.open_stream(client, type: :bidirectional)
        data = "Client #{i} message"
        {:ok, _bytes} = Connection.stream_send(client, stream_id, data, fin: true)
      end

      # Verify all clients get their echo back
      for {i, client} <- clients do
        assert {:ok, _stream_id, received_data, true} =
                 ListenerHelpers.wait_for_any_stream_data(client, 2_000)

        assert received_data == "Client #{i} message"
      end

      # Clean up all clients
      for {_i, client} <- clients do
        ListenerHelpers.stop_client(client)
      end
    end

    test "listener shutdown with active connections" do
      # Start listener
      listener_spec =
        ListenerHelpers.listener_spec(
          handler: EchoHandler,
          handler_opts: []
        )

      listener = start_link_supervised!(listener_spec)
      assert {:ok, {_ip, port}} = Listener.local_address(listener)

      # Connect clients
      clients =
        for _i <- 1..3 do
          {:ok, client} =
            ListenerHelpers.start_client(port, handler_opts: [controlling_process: self()])
          :ok = ListenerHelpers.wait_for_connection(client, 1_000)
          client
        end

      # Verify connections
      assert 3 = Listener.connection_count(listener)

      # Stop listener - use GenServer.stop to ensure terminate is called
      GenServer.stop(listener, :normal)

      # Give time for cleanup (connections close and transition to :closed state)
      # Server connections send CONNECTION_CLOSE frames, clients receive and process them
      # Clients should close and terminate within 50ms after receiving the frame
      Process.sleep(200)

      # Verify all client connections have terminated
      for client <- clients do
        refute Process.alive?(client),
               "Client #{inspect(client)} should have terminated after receiving CONNECTION_CLOSE"
      end
    end

    test "connection close from client side" do
      # Start listener
      listener_spec =
        ListenerHelpers.listener_spec(
          handler: EchoHandler,
          handler_opts: []
        )

      listener = start_link_supervised!(listener_spec)
      assert {:ok, {_ip, port}} = Listener.local_address(listener)

      # Connect client
      assert {:ok, client} =
               ListenerHelpers.start_client(port, handler_opts: [controlling_process: self()])

      assert :ok = ListenerHelpers.wait_for_connection(client, 1_000)

      # Verify connection
      assert 1 = Listener.connection_count(listener)

      # Close from client
      assert :ok = Connection.close(client)

      # Wait for cleanup (closed state has 50ms timeout)
      Process.sleep(150)

      # Connection should be removed
      assert 0 = Listener.connection_count(listener)
    end

    test "large data transfer" do
      # Start listener
      listener_spec =
        ListenerHelpers.listener_spec(
          handler: EchoHandler,
          handler_opts: []
        )

      listener = start_link_supervised!(listener_spec)
      assert {:ok, {_ip, port}} = Listener.local_address(listener)

      # Connect client
      assert {:ok, client} =
               ListenerHelpers.start_client(port, handler_opts: [controlling_process: self()])

      assert :ok = ListenerHelpers.wait_for_connection(client, 1_000)

      # Open stream
      assert {:ok, stream_id} = Connection.open_stream(client, type: :bidirectional)

      # Send large data (1 MB)
      large_data = :crypto.strong_rand_bytes(1024 * 1024)
      assert {:ok, _bytes} = Connection.stream_send(client, stream_id, large_data, fin: true)

      # Wait for echo (may take longer for large data)
      assert {:ok, received_data, true} =
               ListenerHelpers.wait_for_stream_data(client, stream_id, 5_000)

      # Verify data integrity
      assert received_data == large_data

      # Clean up
      ListenerHelpers.stop_client(client)
    end
  end
end
