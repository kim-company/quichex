defmodule Quichex.StreamState do
  @moduledoc """
  Pure functional stream state management.

  Each stream maintains its own state including:
  - Type (bidirectional or unidirectional)
  - Direction (send, recv, or both)
  - Buffer for passive mode
  - FIN flags
  - Flow control windows

  All functions are pure - they take a stream state and return a new stream state.
  No side effects.
  """

  @type stream_id :: non_neg_integer()
  @type stream_type :: :bidirectional | :unidirectional
  @type direction :: :send | :recv | :both

  @type t :: %__MODULE__{
          stream_id: stream_id(),
          type: stream_type(),
          direction: direction(),
          buffer: [buffer_entry()],
          fin_sent: boolean(),
          fin_received: boolean(),
          send_window: non_neg_integer(),
          recv_window: non_neg_integer(),
          bytes_sent: non_neg_integer(),
          bytes_received: non_neg_integer()
        }

  @type buffer_entry :: {data :: binary(), fin :: boolean()}

  defstruct stream_id: nil,
            type: :bidirectional,
            direction: :both,
            buffer: [],
            fin_sent: false,
            fin_received: false,
            send_window: 0,
            recv_window: 0,
            bytes_sent: 0,
            bytes_received: 0

  @doc """
  Creates a new stream state.

  ## Examples

      iex> StreamState.new(4, :bidirectional)
      %StreamState{stream_id: 4, type: :bidirectional, direction: :both}

      iex> StreamState.new(7, :unidirectional)
      %StreamState{stream_id: 7, type: :unidirectional, direction: :send}
  """
  @spec new(stream_id(), stream_type()) :: t()
  def new(stream_id, type) when type in [:bidirectional, :unidirectional] do
    direction =
      case type do
        :bidirectional -> :both
        :unidirectional -> if rem(stream_id, 2) == 0, do: :send, else: :recv
      end

    %__MODULE__{
      stream_id: stream_id,
      type: type,
      direction: direction
    }
  end

  @doc """
  Adds data to the stream's buffer (for passive mode).

  Returns an updated stream state with the data appended to the buffer.

  ## Examples

      iex> stream = StreamState.new(4, :bidirectional)
      iex> stream = StreamState.buffer_data(stream, <<1, 2, 3>>, false)
      iex> length(stream.buffer)
      1
  """
  @spec buffer_data(t(), binary(), boolean()) :: t()
  def buffer_data(%__MODULE__{} = stream, data, fin) when is_binary(data) and is_boolean(fin) do
    entry = {data, fin}
    %{stream | buffer: stream.buffer ++ [entry]}
  end

  @doc """
  Drains buffered data up to max_len bytes.

  Returns a tuple of `{drained_data, updated_stream}` where:
  - `drained_data` is a list of `{data, fin}` tuples
  - `updated_stream` has the drained entries removed from the buffer

  If max_len is reached mid-entry, that entry is kept in the buffer.

  ## Examples

      iex> stream = StreamState.new(4, :bidirectional)
      iex> stream = StreamState.buffer_data(stream, <<1, 2, 3>>, false)
      iex> stream = StreamState.buffer_data(stream, <<4, 5>>, true)
      iex> {drained, _stream} = StreamState.drain_buffer(stream, 100)
      iex> length(drained)
      2
  """
  @spec drain_buffer(t(), non_neg_integer()) :: {[buffer_entry()], t()}
  def drain_buffer(%__MODULE__{buffer: buffer} = stream, max_len) do
    {drained, remaining} = drain_entries(buffer, max_len, [])
    updated_stream = %{stream | buffer: remaining}
    {Enum.reverse(drained), updated_stream}
  end

  defp drain_entries([], _max_len, acc), do: {acc, []}

  defp drain_entries([{data, _fin} = entry | rest], max_len, acc) do
    data_size = byte_size(data)

    if data_size <= max_len do
      # Can drain this entry
      drain_entries(rest, max_len - data_size, [entry | acc])
    else
      # Can't drain this entry without exceeding max_len
      # Keep it in the buffer
      {acc, [entry | rest]}
    end
  end

  @doc """
  Returns the total size of buffered data in bytes.

  ## Examples

      iex> stream = StreamState.new(4, :bidirectional)
      iex> stream = StreamState.buffer_data(stream, <<1, 2, 3>>, false)
      iex> StreamState.buffer_size(stream)
      3
  """
  @spec buffer_size(t()) :: non_neg_integer()
  def buffer_size(%__MODULE__{buffer: buffer}) do
    Enum.reduce(buffer, 0, fn {data, _fin}, acc ->
      acc + byte_size(data)
    end)
  end

  @doc """
  Marks the stream as having sent FIN.

  Returns an updated stream state.
  """
  @spec mark_fin_sent(t()) :: t()
  def mark_fin_sent(%__MODULE__{} = stream) do
    %{stream | fin_sent: true}
  end

  @doc """
  Marks the stream as having received FIN.

  Returns an updated stream state.
  """
  @spec mark_fin_received(t()) :: t()
  def mark_fin_received(%__MODULE__{} = stream) do
    %{stream | fin_received: true}
  end

  @doc """
  Updates bytes sent counter.

  Returns an updated stream state.
  """
  @spec add_bytes_sent(t(), non_neg_integer()) :: t()
  def add_bytes_sent(%__MODULE__{} = stream, bytes) when is_integer(bytes) and bytes >= 0 do
    %{stream | bytes_sent: stream.bytes_sent + bytes}
  end

  @doc """
  Updates bytes received counter.

  Returns an updated stream state.
  """
  @spec add_bytes_received(t(), non_neg_integer()) :: t()
  def add_bytes_received(%__MODULE__{} = stream, bytes) when is_integer(bytes) and bytes >= 0 do
    %{stream | bytes_received: stream.bytes_received + bytes}
  end

  @doc """
  Checks if the stream is finished (both FINs exchanged).

  Returns true if both fin_sent and fin_received are true (for bidirectional streams),
  or if the appropriate FIN is set for unidirectional streams.
  """
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{direction: :both, fin_sent: true, fin_received: true}), do: true
  def finished?(%__MODULE__{direction: :send, fin_sent: true}), do: true
  def finished?(%__MODULE__{direction: :recv, fin_received: true}), do: true
  def finished?(_stream), do: false

  @doc """
  Checks if the stream has any buffered data.
  """
  @spec has_buffered_data?(t()) :: boolean()
  def has_buffered_data?(%__MODULE__{buffer: []}), do: false
  def has_buffered_data?(%__MODULE__{}), do: true
end
