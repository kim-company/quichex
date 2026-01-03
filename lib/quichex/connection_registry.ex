defmodule Quichex.ConnectionRegistry do
  @moduledoc """
  Connection pool managing active QUIC connections.

  A fixed number of worker slots are created at startup. Each worker owns one
  connection at a time; once the connection terminates, the slot returns to the pool.
  """

  use GenServer

  require Logger

  alias Quichex.ConnectionRegistry.Worker

  @type start_result :: {:ok, pid()} | {:error, term()}

  ## Public API

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Starts a new supervised connection if a pool slot is available.
  """
  @spec start_connection(keyword()) :: start_result
  def start_connection(opts) do
    GenServer.call(__MODULE__, {:start_connection, opts})
  end

  ## GenServer callbacks

  @impl true
  def init(_) do
    pool_size = Application.get_env(:quichex, :connection_pool_size, default_pool_size())
    {:ok, worker_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %{
      worker_sup: worker_sup,
      pool_size: pool_size,
      idle_workers: :queue.new(),
      busy_workers: MapSet.new(),
      monitors: %{}
    }

    {:ok, start_workers(pool_size, state)}
  end

  @impl true
  def handle_call({:start_connection, opts}, {caller_pid, _ref}, state) do
    opts_with_defaults = prepare_opts(opts, caller_pid)

    case next_idle_worker(state) do
      {:ok, worker_pid, new_state} ->
        case GenServer.call(worker_pid, {:start_connection, opts_with_defaults}) do
          {:ok, conn_pid} ->
            {:reply, {:ok, conn_pid}, mark_worker_busy(worker_pid, new_state)}

          {:error, reason} ->
            Logger.error("Worker #{inspect(worker_pid)} failed to start connection: #{inspect(reason)}")
            {:reply, {:error, reason}, return_worker(worker_pid, new_state)}
        end

      :none ->
        {:reply, {:error, :connection_limit_reached}, state}
    end
  end

  @impl true
  def handle_info({:worker_ready, worker_pid}, state) do
    {:noreply, return_worker(worker_pid, state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.monitors, pid) do
      {^ref, monitors} ->
        Logger.warning("Connection worker #{inspect(pid)} exited: #{inspect(reason)}")
        state = %{state | monitors: monitors}
        {:noreply, replace_worker(pid, state)}

      {_, _} ->
        {:noreply, state}
    end
  end

  ## Internal helpers

  defp prepare_opts(opts, caller_pid) do
    handler = Keyword.get(opts, :handler, Quichex.Handler.Default)

    opts =
      opts
      |> Keyword.put_new(:controlling_process, caller_pid)

    if handler == Quichex.Handler.Default do
      opts
      |> Keyword.put_new(:handler, Quichex.Handler.Default)
      |> Keyword.update(:handler_opts, [controlling_process: caller_pid], fn handler_opts ->
        Keyword.put_new(handler_opts, :controlling_process, caller_pid)
      end)
    else
      opts
    end
  end

  defp start_workers(count, state) do
    Enum.reduce(1..count, state, fn _, acc ->
      case start_worker(acc) do
        {:ok, _worker_pid, new_state} ->
          new_state

        {:error, reason} ->
          Logger.error("Failed to start connection worker: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp start_worker(state) do
    case DynamicSupervisor.start_child(state.worker_sup, {Worker, self()}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        monitors = Map.put(state.monitors, pid, ref)
        {:ok, pid, %{state | monitors: monitors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp replace_worker(pid, state) do
    state = remove_worker(state, pid)

    case start_worker(state) do
      {:ok, _new_pid, new_state} ->
        new_state

      {:error, error} ->
        Logger.error("Unable to replace connection worker #{inspect(pid)}: #{inspect(error)}")
        state
    end
  end

  defp remove_worker(state, pid) do
    idle =
      state.idle_workers
      |> :queue.to_list()
      |> Enum.reject(&(&1 == pid))
      |> :queue.from_list()
    busy = MapSet.delete(state.busy_workers, pid)
    %{state | idle_workers: idle, busy_workers: busy}
  end

  defp next_idle_worker(state) do
    case :queue.out(state.idle_workers) do
      {{:value, worker_pid}, new_queue} ->
        {:ok, worker_pid, %{state | idle_workers: new_queue}}

      {:empty, _} ->
        :none
    end
  end

  defp return_worker(worker_pid, state) do
    busy = MapSet.delete(state.busy_workers, worker_pid)
    queue = :queue.in(worker_pid, state.idle_workers)
    %{state | busy_workers: busy, idle_workers: queue}
  end

  defp mark_worker_busy(worker_pid, state) do
    %{state | busy_workers: MapSet.put(state.busy_workers, worker_pid)}
  end

  defp default_pool_size do
    max(System.schedulers_online() * 8, 32)
  end
end
