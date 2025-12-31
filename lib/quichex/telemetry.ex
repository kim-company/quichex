defmodule Quichex.Telemetry do
  @moduledoc """
  Telemetry instrumentation helpers for Quichex.

  Provides convenience functions for emitting telemetry events following
  the three-phase pattern (start/stop/exception).

  ## Event Naming Convention

  All Quichex telemetry events follow the format:
  `[:quichex, :component, :operation, :phase]`

  Where:
  - `:component` is one of `:connection`, `:stream`, or `:listener`
  - `:operation` is the operation being performed (e.g., `:connect`, `:send`, `:accept`)
  - `:phase` is one of `:start`, `:stop`, or `:exception`

  ## Three-Phase Pattern

  Most operations emit events in three phases:

  1. **Start** - Emitted when operation begins
     - Measurements: `%{system_time: integer(), monotonic_time: integer()}`
     - Metadata: Context for the operation

  2. **Stop** - Emitted when operation completes successfully
     - Measurements: `%{duration: integer(), monotonic_time: integer()}` + custom measurements
     - Metadata: Start metadata plus results

  3. **Exception** - Emitted when operation raises or fails
     - Measurements: `%{duration: integer()}`
     - Metadata: Start metadata plus error details

  ## Time Units

  All time measurements use native time units (nanoseconds on most systems).
  Use `System.convert_time_unit/3` to convert to other units as needed.

  ## Examples

      # Manual start/stop pattern
      start_time = Quichex.Telemetry.start(
        [:connection, :connect],
        %{host: "example.com", port: 443}
      )

      # ... perform operation ...

      Quichex.Telemetry.stop(
        [:connection, :connect],
        start_time,
        %{host: "example.com", port: 443, conn_pid: pid},
        %{bytes_sent: 1024}
      )

      # Using span for automatic exception handling
      Quichex.Telemetry.span(
        [:stream, :send],
        %{conn_pid: self(), stream_id: 0},
        fn -> send_data() end
      )

  ## Event Reference

  See the telemetry guide for a complete list of events, measurements, and metadata.
  """

  @doc """
  Emits a start event and returns the monotonic start time for later use.

  ## Parameters

  - `event_name` - Event name as list of atoms (without the :start suffix)
  - `metadata` - Map of contextual information
  - `extra_measurements` - Additional measurements to include (optional)

  ## Returns

  The monotonic start time as an integer, to be passed to `stop/4` or `exception/6`.

  ## Examples

      start_time = start([:connection, :connect], %{host: "example.com"})
      # => 123456789000
  """
  @spec start([atom()], map(), map()) :: integer()
  def start(event_name, metadata \\ %{}, extra_measurements \\ %{}) when is_list(event_name) do
    start_time = System.monotonic_time()

    measurements =
      Map.merge(extra_measurements, %{
        system_time: System.system_time(),
        monotonic_time: start_time
      })

    :telemetry.execute([:quichex | event_name] ++ [:start], measurements, metadata)

    start_time
  end

  @doc """
  Emits a stop event with duration calculated from start time.

  ## Parameters

  - `event_name` - Event name as list of atoms (without the :stop suffix)
  - `start_time` - Monotonic start time returned from `start/3`
  - `metadata` - Map of contextual information (should include start metadata)
  - `extra_measurements` - Additional measurements to include (optional)

  ## Examples

      stop(
        [:connection, :connect],
        start_time,
        %{host: "example.com", conn_pid: pid},
        %{bytes_sent: 1024}
      )
  """
  @spec stop([atom()], integer(), map(), map()) :: :ok
  def stop(event_name, start_time, metadata \\ %{}, extra_measurements \\ %{})
      when is_list(event_name) and is_integer(start_time) do
    duration = System.monotonic_time() - start_time

    measurements =
      Map.merge(extra_measurements, %{
        duration: duration,
        monotonic_time: System.monotonic_time()
      })

    :telemetry.execute([:quichex | event_name] ++ [:stop], measurements, metadata)
  end

  @doc """
  Emits an exception event with duration and error details.

  ## Parameters

  - `event_name` - Event name as list of atoms (without the :exception suffix)
  - `start_time` - Monotonic start time returned from `start/3`
  - `kind` - Exception kind (`:error`, `:exit`, `:throw`)
  - `reason` - Exception reason
  - `stacktrace` - Exception stacktrace
  - `metadata` - Map of contextual information (should include start metadata)

  ## Examples

      exception(
        [:connection, :connect],
        start_time,
        :error,
        %RuntimeError{message: "Connection failed"},
        __STACKTRACE__,
        %{host: "example.com"}
      )
  """
  @spec exception([atom()], integer(), atom(), term(), list(), map()) :: :ok
  def exception(event_name, start_time, kind, reason, stacktrace, metadata \\ %{})
      when is_list(event_name) and is_integer(start_time) and kind in [:error, :exit, :throw] do
    duration = System.monotonic_time() - start_time

    measurements = %{
      duration: duration,
      monotonic_time: System.monotonic_time()
    }

    exception_metadata =
      Map.merge(metadata, %{
        kind: kind,
        reason: reason,
        stacktrace: stacktrace
      })

    :telemetry.execute([:quichex | event_name] ++ [:exception], measurements, exception_metadata)
  end

  @doc """
  Emits a single event with measurements and metadata.

  Use this for events that don't follow the three-phase pattern
  (e.g., connection_terminated which is stop-only).

  ## Parameters

  - `event_name` - Full event name as list of atoms
  - `measurements` - Map of measurements
  - `metadata` - Map of contextual information

  ## Examples

      event(
        [:listener, :connection_terminated, :stop],
        %{monotonic_time: System.monotonic_time()},
        %{conn_pid: pid, reason: :normal}
      )
  """
  @spec event([atom()], map(), map()) :: :ok
  def event(event_name, measurements, metadata) when is_list(event_name) do
    :telemetry.execute([:quichex | event_name], measurements, metadata)
  end

  @doc """
  Wraps a function call with automatic start/stop/exception telemetry.

  The function should return `{:ok, result}` or `{:error, reason}` tuples.
  On success, emits a stop event with the result.
  On error or exception, emits an exception event.

  ## Parameters

  - `event_name` - Event name as list of atoms (without phase suffix)
  - `metadata` - Map of contextual information
  - `fun` - Function to execute (arity 0)

  ## Returns

  The result of the function call.

  ## Examples

      result = span(
        [:stream, :send],
        %{conn_pid: self(), stream_id: 0},
        fn -> GenServer.call(pid, {:send, data}) end
      )
  """
  @spec span([atom()], map(), (-> term())) :: term()
  def span(event_name, metadata, fun) when is_list(event_name) and is_function(fun, 0) do
    start_time = start(event_name, metadata)

    try do
      result = fun.()

      case result do
        {:ok, _value} = ok ->
          stop(event_name, start_time, metadata)
          ok

        {:error, reason} ->
          exception(event_name, start_time, :error, reason, [], metadata)
          result

        other ->
          stop(event_name, start_time, metadata)
          other
      end
    rescue
      error ->
        exception(event_name, start_time, :error, error, __STACKTRACE__, metadata)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        exception(event_name, start_time, kind, reason, __STACKTRACE__, metadata)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end
end
