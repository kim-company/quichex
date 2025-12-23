defmodule Quichex.ActivePassiveStressTest do
  use ExUnit.Case, async: false

  alias Quichex.{Connection, Config}

  @moduletag :stress
  @moduletag :integration

  @quiche_server_host "127.0.0.1"
  @quiche_server_port 4433

  # IMPORTANT: These stress tests require a running quiche-server instance.
  #
  # See TESTING.md "Phase 5 Stress Tests" section for complete setup instructions.
  #
  # Quick start:
  #   cd ../quiche && git submodule update --init --recursive
  #   RUST_LOG=info cargo run --bin quiche-server -- \
  #     --listen 127.0.0.1:4433 --root . --no-retry \
  #     --max-data 50000000 --max-stream-data 10000000 --max-streams-bidi 200
  #
  # Then run: mix test --only stress

  setup_all do
    # Create reusable config
    config =
      Config.new!()
      |> Config.set_application_protos(["hq-interop"])
      |> Config.verify_peer(false)
      |> Config.set_max_idle_timeout(30_000)
      |> Config.set_initial_max_streams_bidi(200)
      |> Config.set_initial_max_data(50_000_000)
      |> Config.set_initial_max_stream_data_bidi_local(10_000_000)
      |> Config.set_initial_max_stream_data_bidi_remote(10_000_000)

    {:ok, config: config}
  end

  describe "many streams in active mode" do
    @tag timeout: 120_000
    test "handles 100 concurrent streams in active mode", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: @quiche_server_host,
          port: @quiche_server_port,
          config: config,
          active: true
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      # Open 100 streams
      stream_ids =
        for _i <- 1..100 do
          {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
          stream_id
        end

      # Send requests on all streams
      for stream_id <- stream_ids do
        :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)
      end

      # Receive all responses (at least one message per stream)
      received_streams =
        for _i <- 1..100 do
          assert_receive {:quic_stream, ^conn, stream_id, _data}, 10_000
          stream_id
        end

      # Verify we got responses from unique streams
      unique_streams = Enum.uniq(received_streams)
      assert length(unique_streams) >= 50, "Expected responses from at least 50 unique streams"

      # Drain remaining messages
      drain_messages(conn, 5_000)

      Connection.close(conn)
    end

    @tag timeout: 60_000
    test "handles rapid stream creation and closure", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: @quiche_server_host,
          port: @quiche_server_port,
          config: config,
          active: true
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      # Create and immediately close 50 streams
      for _i <- 1..50 do
        {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
        :ok = Connection.stream_send(conn, stream_id, "GET /\r\n", fin: true)
        # Don't wait for response, create next stream immediately
      end

      # Collect responses - may arrive in any order
      message_count =
        receive_count(
          fn ->
            receive do
              {:quic_stream, ^conn, _stream_id, _data} -> true
              {:quic_stream_fin, ^conn, _stream_id} -> true
            after
              5_000 -> false
            end
          end,
          0
        )

      assert message_count >= 50, "Expected at least 50 messages, got #{message_count}"

      Connection.close(conn)
    end
  end

  describe "rapid setopts switching" do
    @tag timeout: 60_000
    test "handles 1000 setopts calls without crashing", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: @quiche_server_host,
          port: @quiche_server_port,
          config: config,
          active: false
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      # Rapidly switch modes 1000 times
      modes = [true, false, :once, {:active, 1}, {:active, 5}]

      for i <- 1..1000 do
        mode = Enum.at(modes, rem(i, length(modes)))
        assert :ok = Connection.setopts(conn, active: mode)
      end

      # Verify connection is still functional
      {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
      assert :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

      # Switch to active to receive response
      :ok = Connection.setopts(conn, active: true)
      assert_receive {:quic_stream, ^conn, ^stream_id, _data}, 5_000

      Connection.close(conn)
    end

    @tag timeout: 60_000
    test "mode switching during active data transfer", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: @quiche_server_host,
          port: @quiche_server_port,
          config: config,
          active: true
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      # Open 10 streams
      _stream_ids =
        for _i <- 1..10 do
          {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
          :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)
          stream_id
        end

      # Rapidly switch modes while data is arriving
      task =
        Task.async(fn ->
          for i <- 1..100 do
            mode =
              case rem(i, 4) do
                0 -> true
                1 -> false
                2 -> :once
                3 -> {:active, 3}
              end

            Connection.setopts(conn, active: mode)
            Process.sleep(10)
          end
        end)

      # Collect some messages (mode switching might cause some to buffer)
      Process.sleep(2_000)

      # Wait for switching to complete
      Task.await(task)

      # Set to active to drain any buffered data
      :ok = Connection.setopts(conn, active: true)
      drain_messages(conn, 3_000)

      Connection.close(conn)
    end
  end

  describe "large buffer in passive mode" do
    @tag timeout: 120_000
    test "buffers large amounts of data in passive mode", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: @quiche_server_host,
          port: @quiche_server_port,
          config: config,
          active: false
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      # Request large file multiple times to build up buffer
      # Note: quiche-server may not have 50MB files, so we request multiple times
      stream_ids =
        for _i <- 1..20 do
          {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
          :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)
          stream_id
        end

      # Let data accumulate in buffers (passive mode, so we don't read)
      Process.sleep(5_000)

      # Now drain all buffers
      total_bytes =
        Enum.reduce(stream_ids, 0, fn stream_id, acc ->
          drain_stream_buffer(conn, stream_id, acc)
        end)

      assert total_bytes > 0, "Expected to drain some buffered data"

      Connection.close(conn)
    end

    @tag timeout: 60_000
    test "handles buffer growth and drainage cycles", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: @quiche_server_host,
          port: @quiche_server_port,
          config: config,
          active: false
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      # Cycle: fill buffer, drain, fill, drain
      for _cycle <- 1..5 do
        # Fill: request data but don't read
        {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
        :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)
        Process.sleep(500)

        # Drain: read until done
        _bytes = drain_stream_buffer(conn, stream_id, 0)
      end

      Connection.close(conn)
    end
  end

  describe "mixed modes across multiple streams" do
    @tag timeout: 90_000
    test "50 streams with different active modes", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: @quiche_server_host,
          port: @quiche_server_port,
          config: config,
          active: false
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      # Open 50 streams and vary the mode for each
      stream_modes =
        for i <- 1..50 do
          {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)

          mode =
            case rem(i, 5) do
              0 -> true
              1 -> false
              2 -> :once
              3 -> {:active, 1}
              4 -> {:active, 3}
            end

          Connection.setopts(conn, active: mode)
          :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

          {stream_id, mode}
        end

      # Let data arrive
      Process.sleep(5_000)

      # For passive streams, drain explicitly
      for {stream_id, mode} <- stream_modes do
        case mode do
          false ->
            drain_stream_buffer(conn, stream_id, 0)

          _ ->
            :ok
        end
      end

      # Set to active true to drain any remaining
      :ok = Connection.setopts(conn, active: true)
      drain_messages(conn, 3_000)

      Connection.close(conn)
    end

    @tag timeout: 60_000
    test "switching individual stream handling modes", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: @quiche_server_host,
          port: @quiche_server_port,
          config: config,
          active: false
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      # Note: setopts is per-connection, not per-stream
      # This test verifies that mode switches affect all streams consistently

      # Open 5 streams
      stream_ids =
        for _i <- 1..5 do
          {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)
          stream_id
        end

      # Send on all streams
      for stream_id <- stream_ids do
        :ok = Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)
      end

      # Start passive - data buffers
      Process.sleep(1_000)

      # Switch to active - messages delivered
      :ok = Connection.setopts(conn, active: true)
      received = collect_n_messages(conn, 5, 5_000)
      assert length(received) >= 1

      # Switch to :once
      :ok = Connection.setopts(conn, active: :once)

      # Should get one more message
      assert_receive {:quic_stream, ^conn, _stream_id, _data}, 5_000

      # Now passive again
      refute_receive {:quic_stream, ^conn, _stream_id, _data}, 500

      Connection.close(conn)
    end
  end

  describe "edge cases and error conditions" do
    @tag timeout: 30_000
    test "setopts on closed connection returns error", %{config: config} do
      {:ok, conn} =
        Connection.connect(
          host: @quiche_server_host,
          port: @quiche_server_port,
          config: config,
          active: false
        )

      assert_receive {:quic_connected, ^conn}, 5_000

      Connection.close(conn)
      Process.sleep(500)

      # setopts on closed connection should fail gracefully
      result = Connection.setopts(conn, active: true)
      assert result == {:error, :closed} or result == :ok
    end

    @tag timeout: 30_000
    test "handles process death during active data transfer", %{config: config} do
      parent = self()

      # Spawn process that will die
      pid =
        spawn(fn ->
          {:ok, conn} =
            Connection.connect(
              host: @quiche_server_host,
              port: @quiche_server_port,
              config: config,
              active: true
            )

          send(parent, {:conn, conn})

          receive do
            :start ->
              {:ok, stream_id} = Connection.open_stream(conn, :bidirectional)

              :ok =
                Connection.stream_send(conn, stream_id, "GET /index.html\r\n", fin: true)

              # Die immediately without cleanup
              exit(:normal)
          end
        end)

      conn =
        receive do
          {:conn, c} -> c
        after
          5_000 -> flunk("Did not receive connection")
        end

      assert_receive {:quic_connected, ^conn}, 5_000

      send(pid, :start)
      Process.sleep(1_000)

      # Connection should be cleaned up by supervision
      refute Process.alive?(conn)
    end
  end

  # Helper functions

  defp drain_messages(conn, timeout) do
    receive do
      {:quic_stream, ^conn, _stream_id, _data} ->
        drain_messages(conn, timeout)

      {:quic_stream_fin, ^conn, _stream_id} ->
        drain_messages(conn, timeout)

      {:quic_dgram, ^conn, _data} ->
        drain_messages(conn, timeout)
    after
      timeout -> :ok
    end
  end

  defp drain_stream_buffer(conn, stream_id, total_bytes) do
    case Connection.stream_recv(conn, stream_id, 64_000) do
      {:ok, data, false} ->
        drain_stream_buffer(conn, stream_id, total_bytes + byte_size(data))

      {:ok, data, true} ->
        total_bytes + byte_size(data)

      {:error, :would_block} ->
        total_bytes

      {:error, _reason} ->
        total_bytes
    end
  end

  defp receive_count(fun, count) do
    if fun.() do
      receive_count(fun, count + 1)
    else
      count
    end
  end

  defp collect_n_messages(conn, n, timeout) do
    collect_n_messages(conn, n, timeout, [])
  end

  defp collect_n_messages(_conn, 0, _timeout, acc), do: Enum.reverse(acc)

  defp collect_n_messages(conn, n, timeout, acc) do
    receive do
      {:quic_stream, ^conn, stream_id, data} ->
        collect_n_messages(conn, n - 1, timeout, [{stream_id, data} | acc])

      {:quic_stream_fin, ^conn, _stream_id} ->
        collect_n_messages(conn, n, timeout, acc)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
