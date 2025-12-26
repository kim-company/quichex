defmodule Quichex.ConnectionSupervisor do
  @moduledoc """
  Supervisor for a single QUIC connection and its stream handlers.

  Each ConnectionSupervisor manages:
  1. One Connection process (gen_statem) - marked as :significant
  2. One StreamHandlerSupervisor (DynamicSupervisor) for stream handlers

  When the Connection dies, the entire tree shuts down automatically
  due to `auto_shutdown: :any_significant`.

  ## Process Tree

      ConnectionSupervisor [:one_for_one, auto_shutdown: :any_significant]
      ├─ StreamHandlerSupervisor [:temporary] (started FIRST)
      └─ Connection [:temporary, :significant] (started SECOND)
          └─ (StreamHandlers spawned on demand under StreamHandlerSupervisor)

  ## Lifecycle

  1. ConnectionRegistry starts ConnectionSupervisor
  2. ConnectionSupervisor starts StreamHandlerSupervisor
  3. ConnectionSupervisor starts Connection
  4. Connection looks up StreamHandlerSupervisor PID from parent
  5. When Connection dies → entire tree shuts down

  ## Configuration

  Max stream handlers configured via:
  - Per-connection: `max_stream_handlers` option
  - Application env: `config :quichex, max_stream_handlers_per_connection: 1000`
  - Default: 1000
  """

  use Supervisor

  @doc """
  Starts a ConnectionSupervisor with the given connection options.

  Options are passed through to Connection.start_link/1.

  ## Options

    * `:max_stream_handlers` - Override application config for max stream handlers

  All other options are passed to Connection module.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(conn_opts) do
    Supervisor.start_link(__MODULE__, conn_opts)
  end

  @impl true
  def init(conn_opts) do
    # Get max_stream_handlers from opts or application env
    max_stream_handlers =
      Keyword.get(conn_opts, :max_stream_handlers) ||
        Application.get_env(:quichex, :max_stream_handlers_per_connection, 1000)

    children = [
      # StreamHandlerSupervisor - started first
      {Quichex.StreamHandlerSupervisor, max_stream_handlers},
      # Connection - started second, can look up StreamHandlerSupervisor from parent
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

  @doc """
  Gets the StreamHandlerSupervisor PID for this supervisor.

  ## Returns

    * `{:ok, pid}` - StreamHandlerSupervisor process PID
    * `{:error, :not_found}` - Supervisor not found (shouldn't happen in normal operation)
  """
  @spec stream_handler_supervisor_pid(pid()) :: {:ok, pid()} | {:error, :not_found}
  def stream_handler_supervisor_pid(sup_pid) do
    children = Supervisor.which_children(sup_pid)

    case Enum.find(children, fn {id, _pid, _type, _modules} ->
           id == Quichex.StreamHandlerSupervisor
         end) do
      {_id, handler_sup_pid, _type, _modules} -> {:ok, handler_sup_pid}
      nil -> {:error, :not_found}
    end
  end
end
