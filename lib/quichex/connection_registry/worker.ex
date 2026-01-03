defmodule Quichex.ConnectionRegistry.Worker do
  @moduledoc false

  use GenServer

  alias Quichex.ConnectionSupervisor

  defstruct registry: nil, status: :idle, conn_sup: nil, monitor_ref: nil

  ## Public API

  @spec start_link(pid()) :: GenServer.on_start()
  def start_link(registry) when is_pid(registry) do
    GenServer.start_link(__MODULE__, registry)
  end

  ## GenServer callbacks

  @impl true
  def init(registry) do
    Process.flag(:trap_exit, true)
    send(registry, {:worker_ready, self()})
    {:ok, %__MODULE__{registry: registry}}
  end

  @impl true
  def handle_call({:start_connection, opts}, _from, %__MODULE__{status: :idle} = state) do
    case ConnectionSupervisor.start_link(opts) do
      {:ok, sup_pid} ->
        case ConnectionSupervisor.connection_pid(sup_pid) do
          {:ok, conn_pid} ->
            ref = Process.monitor(conn_pid)
            {:reply, {:ok, conn_pid}, %{state | status: :busy, conn_sup: sup_pid, monitor_ref: ref}}

          {:error, reason} ->
            {:reply, {:error, reason}, %{state | conn_sup: nil}}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(_msg, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{monitor_ref: ref} = state) do
    send(state.registry, {:worker_ready, self()})
    {:noreply, %{state | status: :idle, conn_sup: nil, monitor_ref: nil}}
  end

  def handle_info({:EXIT, pid, _reason}, %__MODULE__{conn_sup: pid} = state) do
    send(state.registry, {:worker_ready, self()})
    {:noreply, %{state | status: :idle, conn_sup: nil, monitor_ref: nil}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
