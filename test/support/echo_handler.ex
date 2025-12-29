defmodule Quichex.Test.EchoHandler do
  @moduledoc """
  Simple echo handler for testing.

  Automatically reads from readable streams and echoes data back.
  Useful for validating bidirectional communication in integration tests.
  """

  @behaviour Quichex.Handler

  @impl true
  def init(_conn_pid, opts) do
    initial_state = Keyword.get(opts, :initial_state, %{})
    {:ok, initial_state}
  end

  @impl true
  def handle_connected(_conn_pid, state) do
    {:ok, state}
  end

  @impl true
  def handle_connection_closed(_conn_pid, _reason, state) do
    {:ok, state}
  end

  @impl true
  def handle_stream_opened(_conn_pid, _stream_id, _direction, _type, state) do
    {:ok, state}
  end

  @impl true
  def handle_stream_readable(_conn_pid, stream_id, state) do
    # Automatically read when stream becomes readable
    actions = [{:read_stream, stream_id, []}]
    {:ok, state, actions}
  end

  @impl true
  def handle_stream_data(_conn_pid, stream_id, data, fin, state) do
    # Echo data back on the same stream
    actions = [{:send_data, stream_id, data, fin: fin}]
    {:ok, state, actions}
  end

  @impl true
  def handle_stream_finished(_conn_pid, _stream_id, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end
