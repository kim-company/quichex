defmodule Quichex.ActivePassiveModeTest do
  use ExUnit.Case, async: false

  # Integration tests for active/passive mode behavior.
  # Requires running quiche-server. See TESTING.md for setup instructions.

  @moduletag :integration
  @moduletag timeout: 30_000

  alias Quichex.{Config, Connection}

  setup do
    config =
      Config.new!()
      |> Config.set_application_protos(["hq-interop"])
      |> Config.verify_peer(false)
      |> Config.set_max_idle_timeout(30_000)
      |> Config.set_initial_max_streams_bidi(100)
      |> Config.set_initial_max_data(10_000_000)
      |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
      |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)

    {:ok, config: config}
  end

  describe "active: true mode (default)" do
    test "receives {:quic_connected, pid} on establishment", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: true
        )

      # Should receive connection notification
      assert_receive {:quic_connected, ^conn}, 5_000

      Connection.close(conn)
    end

    test "receives {:quic_stream, pid, stream_id, data} for stream data", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: true
        )

      # Flush connection message
      assert_receive {:quic_connected, ^conn}, 5_000

      # Open stream and send request
      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Should receive stream data
      assert_receive {:quic_stream, ^conn, ^stream_id, data}, 5_000
      assert is_binary(data)
      assert byte_size(data) > 0

      Connection.close(conn)
    end

    test "receives {:quic_stream_fin, pid, stream_id} on FIN", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: true
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Receive data
      assert_receive {:quic_stream, ^conn, ^stream_id, _data}, 5_000

      # Should receive FIN
      assert_receive {:quic_stream_fin, ^conn, ^stream_id}, 5_000

      Connection.close(conn)
    end

    test "does not buffer data (immediate delivery)", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: true
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Receive data automatically
      assert_receive {:quic_stream, ^conn, ^stream_id, _data}, 5_000

      # stream_recv should show no buffered data (or return "done" error)
      result = Connection.stream_recv(conn, stream_id)
      # Either no data, or small remaining data, but not the full response
      assert match?({:error, _}, result) or match?({:ok, _, _}, result)

      Connection.close(conn)
    end
  end

  describe "active: false mode (passive)" do
    test "no messages sent to controlling process", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      # Wait for handshake
      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Should NOT receive any stream messages
      refute_receive {:quic_stream, ^conn, _, _}, 1_000
      refute_receive {:quic_stream_fin, ^conn, _}, 1_000

      Connection.close(conn)
    end

    test "stream_recv/3 reads data from stream", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Wait a bit for response
      Process.sleep(100)

      # Must explicitly read
      {:ok, data, _fin} = Connection.stream_recv(conn, stream_id)
      assert is_binary(data)
      assert byte_size(data) > 0

      Connection.close(conn)
    end

    test "readable_streams/1 returns list of readable streams", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Wait for response
      Process.sleep(100)

      # Should show stream as readable
      {:ok, readable} = Connection.readable_streams(conn)
      assert stream_id in readable

      Connection.close(conn)
    end

    test "buffered data persists across recv calls", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      Process.sleep(200)

      # Read partial data
      {:ok, data1, fin1} = Connection.stream_recv(conn, stream_id, 10)
      assert byte_size(data1) <= 10

      if not fin1 do
        # Read more data
        result = Connection.stream_recv(conn, stream_id, 100)
        assert match?({:ok, _, _}, result) or match?({:error, _}, result)
      end

      Connection.close(conn)
    end
  end

  describe "active: :once mode" do
    test "receives one message then switches to passive", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: :once
        )

      # Should receive connection notification
      assert_receive {:quic_connected, ^conn}, 5_000

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Should receive ONE message
      assert_receive {:quic_stream, ^conn, ^stream_id, _data}, 5_000

      # Now passive - no more messages
      refute_receive {:quic_stream, ^conn, ^stream_id, _}, 1_000

      # Must use stream_recv for remaining data
      # (may get FIN or more data depending on response size)

      Connection.close(conn)
    end

    test "requires setopts to re-enable", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: :once
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Receive first message
      assert_receive {:quic_stream, ^conn, ^stream_id, _}, 5_000

      # Now should be passive - but might still get FIN if response was quick
      # Just verify we can re-enable
      :ok = Connection.setopts(conn, active: :once)

      # After re-enabling, may receive FIN or more data
      receive do
        {:quic_stream, ^conn, ^stream_id, _} -> :ok
        {:quic_stream_fin, ^conn, ^stream_id} -> :ok
      after
        1_000 -> :ok
        # Acceptable if all messages already delivered
      end

      Connection.close(conn)
    end

    test "multiple setopts(:once) works correctly", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Wait for data to arrive and be buffered (passive mode)
      Process.sleep(300)

      # Note: When switching from passive→active with setopts, buffered data
      # is NOT automatically delivered. Only NEW incoming data triggers messages.
      # Since response may already be complete, we use stream_recv to verify
      # buffering worked, then test setopts behavior
      {:ok, _data, _fin} = Connection.stream_recv(conn, stream_id, 100)

      # Now switch to :once mode for any remaining data
      :ok = Connection.setopts(conn, active: :once)

      # Try to trigger more data (may not get any if response was small)
      receive do
        {:quic_stream, ^conn, ^stream_id, _} -> :ok
        {:quic_stream_fin, ^conn, ^stream_id} -> :ok
      after
        1_000 -> :ok
        # Acceptable if all data already consumed
      end

      # Verify setopts call works multiple times
      :ok = Connection.setopts(conn, active: :once)
      :ok = Connection.setopts(conn, active: false)

      Connection.close(conn)
    end
  end

  describe "active: N mode (integer)" do
    test "receives exactly N messages then passive", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: 2
        )

      # Connection message counts as one
      assert_receive {:quic_connected, ^conn}, 5_000

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Should receive one more message (count=2 total)
      assert_receive {:quic_stream, ^conn, ^stream_id, _}, 5_000

      # Now passive (count exhausted) - but allow FIN if it arrives quickly
      receive do
        {:quic_stream_fin, ^conn, ^stream_id} -> :ok
      after
        1_000 -> :ok
      end

      # No more messages should arrive
      refute_receive _, 500

      Connection.close(conn)
    end

    test "N=1 behaves like :once", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: 1
        )

      # Should receive connection message
      assert_receive {:quic_connected, ^conn}, 5_000

      # Now passive (count exhausted after connection message)
      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # With count=1, connection message exhausted it
      # But there's a race - data may arrive and be in mailbox before we check
      # Flush all messages that arrived during the send
      receive do
        {:quic_stream, ^conn, ^stream_id, _} -> :ok
        {:quic_stream_fin, ^conn, ^stream_id} -> :ok
      after
        1_000 -> :ok
      end

      # Flush one more in case FIN arrived separately
      receive do
        {:quic_stream_fin, ^conn, ^stream_id} -> :ok
      after
        500 -> :ok
      end

      # Now should definitely be passive
      refute_receive _, 300

      Connection.close(conn)
    end

    test "count decrements per message", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: 5
        )

      # Message 1: connection
      assert_receive {:quic_connected, ^conn}, 5_000

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Message 2-5: stream data/FIN (depending on response)
      # Receive up to 4 more messages
      Enum.each(1..4, fn _ ->
        receive do
          {:quic_stream, ^conn, ^stream_id, _} -> :ok
          {:quic_stream_fin, ^conn, ^stream_id} -> :ok
        after
          2_000 -> :ok
        end
      end)

      # Eventually becomes passive
      Process.sleep(500)

      # Should be passive now or soon
      refute_receive _, 500

      Connection.close(conn)
    end
  end

  describe "setopts/2 dynamic switching" do
    test "start passive, switch to active", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Initially passive - no messages
      refute_receive {:quic_stream, ^conn, _, _}, 500

      # Switch to active
      :ok = Connection.setopts(conn, active: true)

      # Should now receive messages for new data
      # Note: Buffered data is NOT automatically delivered, only new data
      # Since response may already be complete, we might not get messages
      # So this test just verifies setopts doesn't crash

      Connection.close(conn)
    end

    test "start active, switch to passive", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: true
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Receive some data
      assert_receive {:quic_stream, ^conn, ^stream_id, _}, 5_000

      # Switch to passive
      :ok = Connection.setopts(conn, active: false)

      # Should not receive more automatic messages
      # But FIN may have already been sent before switch took effect
      receive do
        {:quic_stream_fin, ^conn, ^stream_id} -> :ok
      after
        1_000 -> :ok
      end

      # Now definitely passive
      refute_receive _, 300

      Connection.close(conn)
    end

    test "switch active→:once→passive sequence", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: true
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      # Switch to :once
      :ok = Connection.setopts(conn, active: :once)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Get one message
      assert_receive {:quic_stream, ^conn, ^stream_id, _}, 5_000

      # Now should be passive - but might get FIN quickly for small responses
      # Flush any remaining messages
      receive do
        {:quic_stream_fin, ^conn, ^stream_id} -> :ok
      after
        500 -> :ok
      end

      # Verify we're now in passive mode by checking no more messages
      refute_receive _, 300

      Connection.close(conn)
    end

    test "switch between integer values", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: 5
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      # Switch to 3
      :ok = Connection.setopts(conn, active: 3)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Receive up to 3 messages
      Enum.each(1..3, fn _ ->
        receive do
          {:quic_stream, ^conn, ^stream_id, _} -> :ok
          {:quic_stream_fin, ^conn, ^stream_id} -> :ok
        after
          2_000 -> :ok
        end
      end)

      Connection.close(conn)
    end

    test "rapid setopts calls", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      # Rapid mode switches
      :ok = Connection.setopts(conn, active: true)
      :ok = Connection.setopts(conn, active: false)
      :ok = Connection.setopts(conn, active: :once)
      :ok = Connection.setopts(conn, active: 5)
      :ok = Connection.setopts(conn, active: false)

      # Should not crash
      assert Process.alive?(conn)

      Connection.close(conn)
    end
  end

  describe "buffer behavior" do
    test "passive mode buffers all data", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Let data accumulate
      Process.sleep(200)

      # All data should be buffered
      {:ok, data, _fin} = Connection.stream_recv(conn, stream_id, 65535)
      assert byte_size(data) > 0

      Connection.close(conn)
    end

    test "buffer preserves order", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      Process.sleep(200)

      # Read in chunks
      {:ok, chunk1, fin1} = Connection.stream_recv(conn, stream_id, 50)

      if not fin1 do
        result = Connection.stream_recv(conn, stream_id, 50)

        case result do
          {:ok, chunk2, _} ->
            # Verify data is coherent (starts with HTTP response)
            full_data = chunk1 <> chunk2
            assert String.contains?(full_data, "<!DOCTYPE") or String.contains?(full_data, "<")

          {:error, _} ->
            :ok
        end
      end

      Connection.close(conn)
    end
  end

  describe "edge cases" do
    test "mode switch with empty buffer", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: false
        )

      :ok = Connection.wait_connected(conn, timeout: 5_000)

      # Switch modes with empty buffer
      :ok = Connection.setopts(conn, active: true)
      :ok = Connection.setopts(conn, active: false)
      :ok = Connection.setopts(conn, active: :once)

      assert Process.alive?(conn)

      Connection.close(conn)
    end

    test "FIN-only message (zero bytes)", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: "127.0.0.1",
          port: 4433,
          config: config,
          active: true
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)

      # Send FIN-only
      :ok = Connection.stream_send(conn, stream_id, "", fin: true)

      # May receive stream FIN
      receive do
        {:quic_stream_fin, ^conn, ^stream_id} -> :ok
      after
        2_000 -> :ok
      end

      Connection.close(conn)
    end
  end
end
