defmodule Quichex.StreamState do
  @moduledoc """
  Pure functional stream state management.

  Each stream maintains its own state including:
  - Type (bidirectional or unidirectional)
  - Direction (send, recv, or both)
  - FIN flags
  - Flow control windows
  - Byte counters

  ## Pure Functional Design

  All functions are pure - they take a stream state and return a new stream state.
  No side effects, no NIFs, no I/O - just data transformation.

  This separation enables:
  - Easy testing without network I/O
  - Predictable state transitions
  - Functional core / imperative shell pattern

  ## Data Flow

  Stream readable notifications are delivered immediately to the controlling process for minimum latency.
  No buffering occurs at the StreamState level - applications read data on-demand via
  `Connection.stream_recv/3` when ready to process it.
  """

  @type stream_id :: non_neg_integer()
  @type stream_type :: :bidirectional | :unidirectional
  @type direction :: :send | :recv | :both

  @type t :: %__MODULE__{
          stream_id: stream_id(),
          type: stream_type(),
          direction: direction(),
          fin_sent: boolean(),
          fin_received: boolean(),
          send_window: non_neg_integer(),
          recv_window: non_neg_integer(),
          bytes_sent: non_neg_integer(),
          bytes_received: non_neg_integer()
        }

  defstruct stream_id: nil,
            type: :bidirectional,
            direction: :both,
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
  import Bitwise

  @spec new(stream_id(), stream_type(), keyword()) :: t()
  def new(stream_id, type, opts \\ []) when type in [:bidirectional, :unidirectional] do
    direction =
      Keyword.get_lazy(opts, :direction, fn ->
        default_direction(stream_id, type)
      end)

    %__MODULE__{
      stream_id: stream_id,
      type: type,
      direction: direction
    }
  end

  defp default_direction(_stream_id, :bidirectional), do: :both

  defp default_direction(stream_id, :unidirectional) do
    if band(stream_id, 1) == 0, do: :send, else: :recv
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

end
