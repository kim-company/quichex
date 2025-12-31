defmodule Quichex.TelemetryTest do
  use ExUnit.Case, async: true

  alias Quichex.Telemetry

  setup do
    # Generate unique handler ID for each test
    handler_id = "test-handler-#{:erlang.unique_integer([:positive])}"

    # Cleanup on test exit
    on_exit(fn ->
      :telemetry.list_handlers([])
      |> Enum.filter(fn %{id: id} -> id == handler_id end)
      |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)
    end)

    {:ok, handler_id: handler_id}
  end

  describe "Telemetry.start/3" do
    test "emits start event with system_time and monotonic_time", %{handler_id: handler_id} do
      :telemetry.attach(
        handler_id,
        [:quichex, :test, :operation, :start],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      start_time = Telemetry.start([:test, :operation], %{foo: :bar})

      assert is_integer(start_time)

      assert_receive {:telemetry_event, event, measurements, metadata}
      assert event == [:quichex, :test, :operation, :start]
      assert is_integer(measurements.system_time)
      assert is_integer(measurements.monotonic_time)
      assert measurements.monotonic_time == start_time
      assert metadata.foo == :bar
    end

    test "accepts extra measurements", %{handler_id: handler_id} do
      :telemetry.attach(
        handler_id,
        [:quichex, :test, :operation, :start],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.start([:test, :operation], %{}, %{custom: 123})

      assert_receive {:telemetry_event, _event, measurements, _metadata}
      assert measurements.custom == 123
    end
  end

  describe "Telemetry.stop/4" do
    test "emits stop event with duration", %{handler_id: handler_id} do
      :telemetry.attach(
        handler_id,
        [:quichex, :test, :operation, :stop],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      start_time = System.monotonic_time()
      :timer.sleep(1)
      Telemetry.stop([:test, :operation], start_time, %{result: :success})

      assert_receive {:telemetry_event, event, measurements, metadata}
      assert event == [:quichex, :test, :operation, :stop]
      assert is_integer(measurements.duration)
      assert measurements.duration > 0
      assert is_integer(measurements.monotonic_time)
      assert metadata.result == :success
    end

    test "includes extra measurements", %{handler_id: handler_id} do
      :telemetry.attach(
        handler_id,
        [:quichex, :test, :operation, :stop],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      start_time = System.monotonic_time()
      Telemetry.stop([:test, :operation], start_time, %{}, %{bytes: 1024})

      assert_receive {:telemetry_event, _event, measurements, _metadata}
      assert measurements.bytes == 1024
      assert is_integer(measurements.duration)
    end
  end

  describe "Telemetry.exception/6" do
    test "emits exception event with error details", %{handler_id: handler_id} do
      :telemetry.attach(
        handler_id,
        [:quichex, :test, :operation, :exception],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      start_time = System.monotonic_time()
      :timer.sleep(1)

      error = %RuntimeError{message: "test error"}
      stacktrace = [{:module, :function, 3, [file: "test.ex", line: 42]}]

      Telemetry.exception(
        [:test, :operation],
        start_time,
        :error,
        error,
        stacktrace,
        %{context: :test}
      )

      assert_receive {:telemetry_event, event, measurements, metadata}
      assert event == [:quichex, :test, :operation, :exception]
      assert is_integer(measurements.duration)
      assert measurements.duration > 0
      assert metadata.kind == :error
      assert metadata.reason == error
      assert metadata.stacktrace == stacktrace
      assert metadata.context == :test
    end
  end

  describe "Telemetry.event/3" do
    test "emits custom event", %{handler_id: handler_id} do
      :telemetry.attach(
        handler_id,
        [:quichex, :custom, :event, :stop],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      Telemetry.event(
        [:custom, :event, :stop],
        %{count: 5},
        %{source: :test}
      )

      assert_receive {:telemetry_event, event, measurements, metadata}
      assert event == [:quichex, :custom, :event, :stop]
      assert measurements.count == 5
      assert metadata.source == :test
    end
  end

  describe "Telemetry.span/3" do
    test "emits start and stop events for successful operation", %{handler_id: handler_id} do
      :telemetry.attach_many(
        handler_id,
        [
          [:quichex, :test, :span, :start],
          [:quichex, :test, :span, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      result = Telemetry.span([:test, :span], %{id: 123}, fn ->
        :timer.sleep(1)
        {:ok, :result}
      end)

      assert result == {:ok, :result}

      assert_receive {:telemetry_event, start_event, start_measurements, start_metadata}
      assert start_event == [:quichex, :test, :span, :start]
      assert is_integer(start_measurements.monotonic_time)
      assert start_metadata.id == 123

      assert_receive {:telemetry_event, stop_event, stop_measurements, stop_metadata}
      assert stop_event == [:quichex, :test, :span, :stop]
      assert is_integer(stop_measurements.duration)
      assert stop_measurements.duration > 0
      assert stop_metadata.id == 123
    end

    test "emits exception event on error", %{handler_id: handler_id} do
      :telemetry.attach_many(
        handler_id,
        [
          [:quichex, :test, :span, :start],
          [:quichex, :test, :span, :exception]
        ],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      assert_raise RuntimeError, "test error", fn ->
        Telemetry.span([:test, :span], %{id: 456}, fn ->
          raise "test error"
        end)
      end

      assert_receive {:telemetry_event, start_event, _start_measurements, _start_metadata}
      assert start_event == [:quichex, :test, :span, :start]

      assert_receive {:telemetry_event, exception_event, exception_measurements, exception_metadata}
      assert exception_event == [:quichex, :test, :span, :exception]
      assert is_integer(exception_measurements.duration)
      assert exception_metadata.kind == :error
      assert %RuntimeError{} = exception_metadata.reason
      assert is_list(exception_metadata.stacktrace)
    end

    test "emits exception event for {:error, reason} tuples", %{handler_id: handler_id} do
      :telemetry.attach_many(
        handler_id,
        [
          [:quichex, :test, :span, :start],
          [:quichex, :test, :span, :stop],
          [:quichex, :test, :span, :exception]
        ],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      result = Telemetry.span([:test, :span], %{}, fn ->
        {:error, :not_found}
      end)

      assert result == {:error, :not_found}

      # Should receive start event
      assert_receive {:telemetry_event, start_event, _start_measurements, _start_metadata}
      assert start_event == [:quichex, :test, :span, :start]

      # Should receive exception event for error tuple
      assert_receive {:telemetry_event, exception_event, _exception_measurements, exception_metadata}
      assert exception_event == [:quichex, :test, :span, :exception]
      assert exception_metadata.kind == :error
      assert exception_metadata.reason == :not_found
    end
  end

  describe "Integration: connection events" do
    test "connection lifecycle emits expected events" do
      handler_id = "connection-lifecycle-test"

      :telemetry.attach_many(
        handler_id,
        [
          [:quichex, :connection, :connect, :start],
          [:quichex, :connection, :connect, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      config = Quichex.Config.new!()
        |> Quichex.Config.set_application_protos(["h3"])
        |> Quichex.Config.verify_peer(false)

      # Start a connection
      {:ok, _conn} = Quichex.start_connection(
        host: "127.0.0.1",
        port: 9999,
        config: config
      )

      # Should receive connect start event
      assert_receive {:telemetry_event, connect_start, start_measurements, start_metadata}, 500
      assert connect_start == [:quichex, :connection, :connect, :start]
      assert is_integer(start_measurements.system_time)
      assert start_metadata.host == "127.0.0.1"
      assert start_metadata.port == 9999
      assert start_metadata.mode == :client

      # Should receive connect stop event
      assert_receive {:telemetry_event, connect_stop, stop_measurements, stop_metadata}, 500
      assert connect_stop == [:quichex, :connection, :connect, :stop]
      assert is_integer(stop_measurements.duration)
      assert is_pid(stop_metadata.conn_pid)
      assert stop_metadata.host == "127.0.0.1"

      :telemetry.detach(handler_id)
    end
  end

  describe "Integration: stream events" do
    test "stream operations emit expected events" do
      handler_id = "stream-ops-test"

      :telemetry.attach_many(
        handler_id,
        [
          [:quichex, :stream, :open, :start],
          [:quichex, :stream, :open, :stop],
          [:quichex, :stream, :open, :exception]
        ],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      config = Quichex.Config.new!()
        |> Quichex.Config.set_application_protos(["h3"])
        |> Quichex.Config.verify_peer(false)

      {:ok, conn} = Quichex.start_connection(
        host: "127.0.0.1",
        port: 9999,
        config: config
      )

      # Try to open a stream (will fail since not connected)
      result = Quichex.Connection.open_stream(conn, :bidirectional)

      # Should receive stream open start event
      assert_receive {:telemetry_event, open_start, open_start_measurements, open_start_metadata}
      assert open_start == [:quichex, :stream, :open, :start]
      assert is_integer(open_start_measurements.system_time)
      assert open_start_metadata.type == :bidirectional

      # Should receive either stop or exception based on connection state
      case result do
        {:ok, stream_id} ->
          # Connection was fast enough - got stop event
          assert_receive {:telemetry_event, open_stop, open_stop_measurements, open_stop_metadata}
          assert open_stop == [:quichex, :stream, :open, :stop]
          assert is_integer(open_stop_measurements.duration)
          assert open_stop_metadata.stream_id == stream_id

        {:error, reason} ->
          # Not connected - got exception event
          assert_receive {:telemetry_event, open_exception, exception_measurements, exception_metadata}
          assert open_exception == [:quichex, :stream, :open, :exception]
          assert is_integer(exception_measurements.duration)
          assert exception_metadata.kind == :error
          assert exception_metadata.reason == reason
      end

      :telemetry.detach(handler_id)
    end
  end

  describe "Measurements use native time units" do
    test "duration is in native time units", %{handler_id: handler_id} do
      :telemetry.attach(
        handler_id,
        [:quichex, :test, :timing, :stop],
        fn event, measurements, metadata, _config ->
          send(self(), {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      start_time = System.monotonic_time()
      :timer.sleep(10)  # Sleep 10ms
      Telemetry.stop([:test, :timing], start_time, %{})

      assert_receive {:telemetry_event, _event, measurements, _metadata}

      # Duration should be in native units (nanoseconds on most systems)
      # 10ms = 10_000_000 nanoseconds
      assert measurements.duration > 1_000_000  # At least 1ms in nanoseconds

      # Can convert to milliseconds
      duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
      assert duration_ms >= 10
    end
  end
end
