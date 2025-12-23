defmodule Quichex.StreamWorker do
  @moduledoc """
  Optional process for handling stream I/O independently.

  StreamWorkers allow QUIC stream operations to run in parallel, outside
  the main connection process. This is critical for performance when:
  - Sending large amounts of data (> 64KB)
  - Handling long-lived streams (WebTransport pattern)
  - Maximizing multi-core utilization

  ## Design Constraints

  Workers **only** call `connection_stream_send` NIF, NOT `connection_send`.
  Packet generation and batching remains in the main connection process.

  ## Lifecycle

  1. Spawned by StreamDispatcher when threshold exceeded
  2. Handles send operations for ONE stream
  3. Notifies parent connection when bytes sent
  4. Parent triggers packet generation
  5. Terminates when stream closes or parent exits
  """

  use GenServer
  require Logger

  alias Quichex.Native

  defstruct [
    :conn_resource,
    :stream_id,
    :parent_pid,
    bytes_sent: 0,
    bytes_received: 0,
    send_queue: :queue.new(),
    fin_sent: false
  ]

  @type t :: %__MODULE__{
          conn_resource: reference(),
          stream_id: non_neg_integer(),
          parent_pid: pid(),
          bytes_sent: non_neg_integer(),
          bytes_received: non_neg_integer(),
          send_queue: :queue.queue(),
          fin_sent: boolean()
        }

  # Client API

  @doc """
  Starts a stream worker process.

  ## Options

    * `:conn_resource` - NIF resource for the QUIC connection
    * `:stream_id` - Stream ID this worker handles
    * `:parent_pid` - PID of parent connection process
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    conn_resource = Keyword.fetch!(opts, :conn_resource)
    stream_id = Keyword.fetch!(opts, :stream_id)
    parent_pid = Keyword.fetch!(opts, :parent_pid)

    GenServer.start_link(__MODULE__, {conn_resource, stream_id, parent_pid})
  end

  @doc """
  Asynchronously sends data on the stream.

  Returns immediately. Worker processes the send in the background.
  """
  @spec async_send(pid(), binary(), boolean()) :: :ok | {:error, term()}
  def async_send(worker_pid, data, fin) when is_binary(data) and is_boolean(fin) do
    try do
      GenServer.cast(worker_pid, {:send, data, fin})
    catch
      :exit, reason ->
        {:error, {:worker_dead, reason}}
    end
  end

  @doc """
  Synchronously sends data on the stream.

  Blocks until data is written to quiche buffers (not until ACKed).
  """
  @spec sync_send(pid(), binary(), boolean(), timeout()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def sync_send(worker_pid, data, fin, timeout \\ 5000) do
    try do
      GenServer.call(worker_pid, {:send_sync, data, fin}, timeout)
    catch
      :exit, reason ->
        {:error, {:worker_dead, reason}}
    end
  end

  @doc """
  Gets worker statistics.
  """
  @spec stats(pid()) :: {:ok, map()} | {:error, term()}
  def stats(worker_pid) do
    try do
      GenServer.call(worker_pid, :stats)
    catch
      :exit, reason ->
        {:error, {:worker_dead, reason}}
    end
  end

  # GenServer Callbacks

  @impl true
  def init({conn_resource, stream_id, parent_pid}) do
    # Link to parent so we die if connection dies
    Process.link(parent_pid)

    state = %__MODULE__{
      conn_resource: conn_resource,
      stream_id: stream_id,
      parent_pid: parent_pid
    }

    Logger.debug("StreamWorker started for stream #{stream_id}")

    {:ok, state}
  end

  @impl true
  def handle_cast({:send, data, fin}, state) do
    # Async send - don't block caller
    case do_send(state, data, fin) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("StreamWorker #{state.stream_id} send failed: #{inspect(reason)}")
        {:stop, {:send_error, reason}, state}
    end
  end

  @impl true
  def handle_call({:send_sync, data, fin}, _from, state) do
    # Sync send - reply with result
    case do_send(state, data, fin) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.bytes_sent - state.bytes_sent}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      stream_id: state.stream_id,
      bytes_sent: state.bytes_sent,
      bytes_received: state.bytes_received,
      fin_sent: state.fin_sent,
      queue_length: :queue.len(state.send_queue)
    }

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("StreamWorker #{state.stream_id} terminating: #{inspect(reason)}")
    :ok
  end

  # Private Functions

  @doc false
  defp do_send(state, data, fin) do
    if state.fin_sent do
      {:error, "stream already finished"}
    else
      # Call NIF to write data to stream buffers
      # NOTE: This does NOT trigger packet send - parent connection handles that
      case Native.connection_stream_send(state.conn_resource, state.stream_id, data, fin) do
        {:ok, bytes_written} ->
          # Notify parent that we wrote data (parent will generate packets)
          send(state.parent_pid, {:stream_worker_sent, state.stream_id, bytes_written})

          new_state = %{
            state
            | bytes_sent: state.bytes_sent + bytes_written,
              fin_sent: fin
          }

          {:ok, new_state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
