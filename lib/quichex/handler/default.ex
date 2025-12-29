defmodule Quichex.Handler.Default do
  @moduledoc """
  Default handler that sends messages to a controlling process.

  Automatically used when no custom handler is specified. Maintains backward
  compatibility by sending traditional QUIC messages:

  - `{:quic_connected, conn_pid}`
  - `{:quic_stream_opened, conn_pid, stream_id, direction, stream_type}`
  - `{:quic_stream_readable, conn_pid, stream_id}`
  - `{:quic_stream_finished, conn_pid, stream_id}`
  - `{:quic_connection_closed, conn_pid, reason}`

  The controlling process defaults to the caller of `start_connection/1`.
  """

  @behaviour Quichex.Handler

  require Logger

  @impl true
  def init(_conn_pid, opts) do
    case Keyword.fetch(opts, :controlling_process) do
      {:ok, pid} when is_pid(pid) ->
        {:ok, pid}

      {:ok, invalid} ->
        {:error, {:invalid_controlling_process, invalid}}

      :error ->
        {:error, :controlling_process_required}
    end
  end

  @impl true
  def handle_connected(conn_pid, controlling_process) do
    send(controlling_process, {:quic_connected, conn_pid})
    {:ok, controlling_process}
  end

  @impl true
  def handle_connection_closed(conn_pid, reason, controlling_process) do
    send(controlling_process, {:quic_connection_closed, conn_pid, reason})
    {:ok, controlling_process}
  end

  @impl true
  def handle_stream_opened(conn_pid, stream_id, direction, stream_type, controlling_process) do
    send(
      controlling_process,
      {:quic_stream_opened, conn_pid, stream_id, direction, stream_type}
    )

    {:ok, controlling_process}
  end

  @impl true
  def handle_stream_readable(conn_pid, stream_id, controlling_process) do
    send(controlling_process, {:quic_stream_readable, conn_pid, stream_id})
    {:ok, controlling_process}
  end

  @impl true
  def handle_stream_finished(conn_pid, stream_id, controlling_process) do
    send(controlling_process, {:quic_stream_finished, conn_pid, stream_id})
    {:ok, controlling_process}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end
