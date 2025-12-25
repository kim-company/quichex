defmodule Quichex.StreamHandler.Message do
  @moduledoc """
  Simple message-passing stream handler.

  Sends stream data as messages to a controlling process. This is the simplest
  handler for basic request/response patterns where you want to handle data
  in receive blocks rather than callbacks.

  ## Usage

      {:ok, handler} = Connection.open_stream(conn,
        handler: Quichex.StreamHandler.Message,
        handler_opts: [controlling_process: self()]
      )

      StreamHandler.send_data(handler, "GET /\\r\\n", fin: true)

      receive do
        {:quic_stream, ^handler, data} -> IO.puts(data)
        {:quic_stream_fin, ^handler} -> IO.puts("Stream closed")
      end

  ## Messages Sent

  - `{:quic_stream, handler_pid, data}` - stream data received
  - `{:quic_stream_fin, handler_pid}` - stream FIN received

  ## Options

  - `:controlling_process` (required) - PID to send messages to
  """

  @behaviour Quichex.StreamHandler.Behaviour

  defstruct [:stream_id, :controlling_process]

  @impl true
  def init(stream_id, _direction, _stream_type, opts) do
    case Keyword.fetch(opts, :controlling_process) do
      {:ok, pid} when is_pid(pid) ->
        state = %__MODULE__{
          stream_id: stream_id,
          controlling_process: pid
        }
        {:ok, state}

      {:ok, other} ->
        {:error, "controlling_process must be a PID, got: #{inspect(other)}"}

      :error ->
        {:error, "controlling_process option is required"}
    end
  end

  @impl true
  def handle_data(data, fin, state) do
    # Send data message
    actions = [{:notify, state.controlling_process, {:quic_stream, self(), data}}]

    # Send FIN message if stream is finishing
    actions =
      if fin do
        [{:notify, state.controlling_process, {:quic_stream_fin, self()}} | actions]
      else
        actions
      end

    {:ok, actions, state}
  end

  @impl true
  def handle_stream_closed(_reason, _state), do: :ok

  @impl true
  def terminate(_reason, _state), do: :ok
end
