defmodule Quichex.HandlerExecutor do
  @moduledoc """
  Global pool executing handler callbacks outside of the connection process.

  Connections submit handler jobs which are executed with bounded concurrency.
  Results are sent back to the originating connection via messages.
  """

  use GenServer

  require Logger

  defmodule Job do
    @moduledoc false
    defstruct [:job_ref, :conn_pid, :handler_module, :callback, :args, :handler_state]
  end

  @type job_ref :: reference()

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Submit a handler job to the executor.
  """
  @spec submit(%{
          conn_pid: pid(),
          handler_module: module(),
          callback: atom(),
          args: [term()],
          handler_state: term()
        }) :: {:ok, job_ref()}
  def submit(attrs) do
    GenServer.call(__MODULE__, {:submit, attrs})
  end

  @doc """
  Cancel any queued or running jobs for the given connection.
  """
  @spec cancel_jobs(pid()) :: :ok
  def cancel_jobs(conn_pid) do
    GenServer.cast(__MODULE__, {:cancel_jobs, conn_pid})
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    max_workers =
      Application.get_env(:quichex, :handler_pool_size, default_worker_count())

    {:ok, task_sup} =
      Task.Supervisor.start_link(
        name: Module.concat(__MODULE__, TaskSupervisor)
      )

    state = %{
      task_sup: task_sup,
      max_workers: max_workers,
      active: %{},      # job_ref => %{conn_pid, task_ref, task_pid}
      queue: :queue.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:submit, attrs}, _from, state) do
    job = build_job(attrs)
    {:reply, {:ok, job.job_ref}, maybe_start_job(job, state)}
  end

  @impl true
  def handle_cast({:cancel_jobs, conn_pid}, state) do
    # Cancel queued jobs
    queue =
      state.queue
      |> :queue.to_list()
      |> Enum.reject(fn %Job{conn_pid: pid} -> pid == conn_pid end)
      |> :queue.from_list()

    Enum.each(state.active, fn
      {job_ref, %{conn_pid: ^conn_pid, task_pid: task_pid}} ->
        Logger.debug("Cancelling handler job #{inspect(job_ref)} for #{inspect(conn_pid)}")
        Process.exit(task_pid, :shutdown)

      _ ->
        :ok
    end)

    {:noreply, %{state | queue: queue}}
  end

  @impl true
  def handle_info({:handler_complete, job_ref, result}, state) do
    case Map.pop(state.active, job_ref) do
      {nil, _active} ->
        {:noreply, maybe_start_next(state)}

      {%{conn_pid: conn_pid}, active} ->
        send(conn_pid, {:handler_result, job_ref, result})
        {:noreply, maybe_start_next(%{state | active: active})}
    end
  end

  @impl true
  def handle_info({:DOWN, task_ref, :process, _pid, reason}, state) do
    {job_ref, job_info} =
      Enum.find(state.active, fn {_job_ref, info} -> info.task_ref == task_ref end) ||
        {nil, nil}

    cond do
      job_ref == nil ->
        {:noreply, state}

      reason != :normal ->
        send(job_info.conn_pid, {:handler_result, job_ref, {:error, {:exit, reason}}})
        {:noreply, maybe_start_next(%{state | active: Map.delete(state.active, job_ref)})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({ref, _payload}, state) when is_reference(ref) do
    # Ignore Task.async result messages (we send explicit completion events)
    {:noreply, state}
  end

  ## Helpers

  defp build_job(attrs) do
    struct!(Job, Map.put(attrs, :job_ref, make_ref()))
  end

  defp maybe_start_job(job, state) do
    if map_size(state.active) < state.max_workers do
      start_job(job, state)
    else
      queue = :queue.in(job, state.queue)
      %{state | queue: queue}
    end
  end

  defp default_worker_count do
    max(System.schedulers_online() * 4, 16)
  end

  defp maybe_start_next(%{queue: queue} = state) do
    case :queue.out(queue) do
      {{:value, job}, new_queue} ->
        state
        |> Map.put(:queue, new_queue)
        |> start_job(job)

      {:empty, _} ->
        state
    end
  end

  defp start_job(%Job{} = job, state) do
    executor = self()

    task =
      Task.Supervisor.async_nolink(state.task_sup, fn ->
        result =
          try do
            apply(job.handler_module, job.callback, job.args ++ [job.handler_state])
          rescue
            exception ->
              {:error, {:exception, exception, __STACKTRACE__}}
          catch
            kind, reason ->
              {:error, {:throw, kind, reason}}
          end

        send(executor, {:handler_complete, job.job_ref, result})
      end)

    active =
      Map.put(state.active, job.job_ref, %{
        conn_pid: job.conn_pid,
        task_ref: task.ref,
        task_pid: task.pid
      })

    %{state | active: active}
  end
end
