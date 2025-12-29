defmodule Quichex.ConnectionSupervisor do
  @moduledoc """
  Supervisor for a single QUIC connection.

  Each ConnectionSupervisor manages one Connection process (gen_statem).
  When the Connection dies, the supervisor shuts down automatically.

  ## Process Tree

      ConnectionSupervisor [:one_for_one, auto_shutdown: :any_significant]
      └─ Connection [:temporary, :significant]

  ## Lifecycle

  1. ConnectionRegistry starts ConnectionSupervisor
  2. ConnectionSupervisor starts Connection
  3. When Connection dies → supervisor shuts down
  """

  use Supervisor

  @doc """
  Starts a ConnectionSupervisor with the given connection options.

  Options are passed through to Connection.start_link/1.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(conn_opts) do
    Supervisor.start_link(__MODULE__, conn_opts)
  end

  @impl true
  def init(conn_opts) do
    children = [
      %{
        id: Quichex.Connection,
        start: {Quichex.Connection, :start_link, [conn_opts]},
        restart: :temporary,
        significant: true,
        type: :worker
      }
    ]

    Supervisor.init(children, strategy: :one_for_one, auto_shutdown: :any_significant)
  end

  @doc """
  Gets the Connection PID for this supervisor.

  ## Returns

    * `{:ok, pid}` - Connection process PID
    * `{:error, :not_found}` - Connection not found (shouldn't happen in normal operation)
  """
  @spec connection_pid(pid()) :: {:ok, pid()} | {:error, :not_found}
  def connection_pid(sup_pid) do
    children = Supervisor.which_children(sup_pid)

    case Enum.find(children, fn {id, _pid, _type, _modules} -> id == Quichex.Connection end) do
      {_id, conn_pid, _type, _modules} -> {:ok, conn_pid}
      nil -> {:error, :not_found}
    end
  end

end
