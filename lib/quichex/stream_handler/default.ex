defmodule Quichex.StreamHandler.Default do
  @moduledoc """
  Internal default stream handler for imperative API.

  Always delivers stream data as messages to the controlling process.
  No buffering - data is delivered immediately for minimum latency.

  Users can implement their own buffering in custom handlers if needed.

  ## Messages Sent

  - `{:quic_stream, conn_pid, stream_id, data}` - stream data received
  - `{:quic_stream_fin, conn_pid, stream_id}` - stream FIN received
  """

  @behaviour Quichex.StreamHandler.Behaviour

  defstruct [:stream_id, :controlling_process, :conn_pid]

  @impl true
  def init(stream_id, _direction, _stream_type, opts) do
    state = %__MODULE__{
      stream_id: stream_id,
      controlling_process: Keyword.fetch!(opts, :controlling_process),
      conn_pid: Keyword.fetch!(opts, :conn_pid)
    }

    {:ok, state}
  end

  @impl true
  def handle_data(data, fin, state) do
    # Always send messages immediately - no buffering
    actions = [{:notify, state.controlling_process, {:quic_stream, state.conn_pid, state.stream_id, data}}]

    actions =
      if fin do
        [{:notify, state.controlling_process, {:quic_stream_fin, state.conn_pid, state.stream_id}} | actions]
      else
        actions
      end

    {:ok, actions, state}
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
