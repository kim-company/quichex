defmodule Quichex.StreamHandler.Behaviour do
  @moduledoc """
  Behavior for handling QUIC stream lifecycle and data.

  Each stream runs in its own supervised process, enabling:
  - Blocking operations (video decode, file I/O) without affecting other streams
  - Fault isolation (stream crash doesn't kill connection)
  - Parallel processing across CPU cores

  ## Example

      defmodule MyApp.EchoHandler do
        @behaviour Quichex.StreamHandler.Behaviour

        def init(_stream_id, _direction, _stream_type, _opts) do
          {:ok, %{}}
        end

        def handle_data(data, _fin, state) do
          # Echo data back
          actions = [{:send, data}]
          {:ok, actions, state}
        end

        def handle_stream_closed(_reason, _state) do
          :ok
        end

        def terminate(_reason, _state) do
          :ok
        end
      end

  ## MoQ Use Case

  For Media over QUIC (MoQ), you can have separate handlers for video, audio,
  and metadata streams, each running independently:

      defmodule MyApp.VideoHandler do
        def init(stream_id, :incoming, :unidirectional, opts) do
          {:ok, decoder} = VideoDecoder.init(opts[:codec])
          {:ok, %{stream_id: stream_id, decoder: decoder, buffer: <<>>}}
        end

        def handle_data(data, _fin, state) do
          # Heavy decode operation - runs in stream process, doesn't block others
          state = %{state | buffer: state.buffer <> data}

          case VideoDecoder.decode(state.decoder, state.buffer) do
            {:ok, frames, new_buffer} ->
              # Notify application of decoded frames
              actions = Enum.map(frames, fn frame ->
                {:notify, self(), {:video_frame, state.stream_id, frame}}
              end)

              {:ok, actions, %{state | buffer: new_buffer}}

            {:need_more_data, new_buffer} ->
              {:ok, %{state | buffer: new_buffer}}
          end
        end

        def handle_stream_closed(_reason, state) do
          VideoDecoder.cleanup(state.decoder)
          :ok
        end

        def terminate(_reason, state) do
          VideoDecoder.cleanup(state.decoder)
          :ok
        end
      end
  """

  @type stream_id :: non_neg_integer()
  @type direction :: :incoming | :outgoing
  @type stream_type :: :bidirectional | :unidirectional
  @type state :: term()
  @type action ::
          {:send, binary()}
          | {:send, binary(), fin :: boolean()}
          | {:close, error_code :: non_neg_integer()}
          | {:notify, pid(), message :: term()}

  @doc """
  Called when the stream handler is started.

  Return `{:ok, state}` to continue with initial state, or
  `{:stop, reason}` to reject the stream.

  ## Arguments

    * `stream_id` - The QUIC stream ID
    * `direction` - `:incoming` (peer-initiated) or `:outgoing` (user-initiated)
    * `stream_type` - `:bidirectional` or `:unidirectional`
    * `opts` - Options passed from connection config or open_stream call

  ## Example

      def init(stream_id, :incoming, :unidirectional, opts) do
        codec = Keyword.get(opts, :codec, :h264)
        {:ok, decoder} = Decoder.init(codec)
        {:ok, %{stream_id: stream_id, decoder: decoder}}
      end
  """
  @callback init(stream_id(), direction(), stream_type(), opts :: term()) ::
              {:ok, state()} | {:stop, reason :: term()}

  @doc """
  Called when data arrives on the stream.

  Return `{:ok, new_state}` to continue,
  `{:ok, actions, new_state}` to execute actions (send data, notify app, etc.),
  or `{:stop, reason, state}` to terminate the handler.

  ## Arguments

    * `data` - Binary data received
    * `fin` - Whether this is the final data (FIN flag set)
    * `state` - Current handler state

  ## Actions

    * `{:send, data}` - Send data on this stream
    * `{:send, data, fin: true}` - Send data with FIN (close write side)
    * `{:close, error_code}` - Close stream with application error code
    * `{:notify, pid, message}` - Send arbitrary message to process

  ## Example

      def handle_data(data, fin, state) do
        # Process data (can block - runs in stream process)
        processed = heavy_processing(data)

        # Send response and notify application
        actions = [
          {:send, processed, fin: fin},
          {:notify, self(), {:processed, byte_size(processed)}}
        ]

        {:ok, actions, state}
      end
  """
  @callback handle_data(data :: binary(), fin :: boolean(), state()) ::
              {:ok, state()}
              | {:ok, [action()], state()}
              | {:stop, reason :: term(), state()}

  @doc """
  Called when the stream is closed (either normally or due to error).

  This is called before `terminate/2` and allows cleanup of stream-specific
  resources.

  ## Arguments

    * `reason` - Reason for closure (`:normal`, `:reset`, or error tuple)
    * `state` - Current handler state
  """
  @callback handle_stream_closed(reason :: term(), state()) :: :ok

  @doc """
  Called when the handler process is terminating.

  This is called after `handle_stream_closed/2` (if applicable) and
  allows final cleanup of resources.

  ## Arguments

    * `reason` - Termination reason
    * `state` - Final handler state
  """
  @callback terminate(reason :: term(), state()) :: :ok
end
