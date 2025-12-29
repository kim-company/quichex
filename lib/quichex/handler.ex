defmodule Quichex.Handler do
  @moduledoc """
  Behaviour for handling QUIC connection and stream events with custom logic.

  Implement this behaviour to process QUIC events declaratively while maintaining
  state across callbacks. The default implementation (`Quichex.Handler.Default`)
  sends messages to a controlling process for backward compatibility.

  ## Usage

      defmodule MyApp.QuicHandler do
        @behaviour Quichex.Handler

        def init(_conn_pid, _opts), do: {:ok, %{}}
        def handle_connected(_pid, state), do: {:ok, state}
        def handle_stream_readable(pid, stream_id, state) do
          {:ok, data, _fin} = Quichex.stream_recv(pid, stream_id)
          IO.inspect(data, label: "Stream \#{stream_id}")
          {:ok, state}
        end
        # ... implement other required callbacks
      end

      {:ok, conn} = Quichex.start_connection(
        host: "example.com",
        port: 443,
        config: config,
        handler: MyApp.QuicHandler
      )
  """

  @type stream_id :: non_neg_integer()
  @type direction :: :incoming | :outgoing
  @type stream_type :: :bidirectional | :unidirectional
  @type handler_state :: term()

  @doc """
  Initialize handler state when connection starts.

  Return `{:ok, state}` to proceed or `{:error, reason}` to abort connection.
  """
  @callback init(conn_pid :: pid(), opts :: keyword()) ::
              {:ok, handler_state} | {:error, reason :: term()}

  @doc """
  Called when QUIC handshake completes and connection is ready.
  """
  @callback handle_connected(conn_pid :: pid(), handler_state) ::
              {:ok, new_handler_state :: handler_state}

  @doc """
  Called when connection closes, either gracefully or due to error.
  """
  @callback handle_connection_closed(conn_pid :: pid(), reason :: term(), handler_state) ::
              {:ok, new_handler_state :: handler_state}

  @doc """
  Called when a new stream is detected (peer-initiated or locally-initiated).
  """
  @callback handle_stream_opened(
              conn_pid :: pid(),
              stream_id,
              direction,
              stream_type,
              handler_state
            ) ::
              {:ok, new_handler_state :: handler_state}

  @doc """
  Called when a stream has data available. Use `Quichex.stream_recv/2` to read it.

  May be called multiple times as more data arrives on the same stream.
  """
  @callback handle_stream_readable(conn_pid :: pid(), stream_id, handler_state) ::
              {:ok, new_handler_state :: handler_state}

  @doc """
  Called when a stream receives FIN flag (no more data will arrive).

  Optional callback, not yet fully implemented in the codebase.
  """
  @callback handle_stream_finished(conn_pid :: pid(), stream_id, handler_state) ::
              {:ok, new_handler_state :: handler_state}

  @doc """
  Called when connection terminates. Optional cleanup callback.
  """
  @callback terminate(reason :: term(), handler_state) :: :ok

  @optional_callbacks [
    terminate: 2,
    handle_stream_finished: 3
  ]
end
