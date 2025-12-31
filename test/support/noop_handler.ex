defmodule Quichex.Test.NoOpHandler do
  @moduledoc """
  A no-op handler for unit tests that don't need message notifications.

  This handler implements the Quichex.Handler behaviour but doesn't send
  any messages to the controlling process. Useful for unit tests that just
  want to test Connection functionality without dealing with handler messages.
  """

  @behaviour Quichex.Handler

  @impl true
  def init(_conn_pid, _opts) do
    {:ok, nil}
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
  def handle_stream_opened(_conn_pid, _stream_id, _direction, _stream_type, state) do
    {:ok, state}
  end

  @impl true
  def handle_stream_readable(_conn_pid, _stream_id, state) do
    {:ok, state}
  end

  @impl true
  def handle_stream_data(_conn_pid, _stream_id, _data, _fin, state) do
    {:ok, state}
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
