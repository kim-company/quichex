defmodule Quichex.ConnectionRegistry do
  @moduledoc """
  DynamicSupervisor managing all QUIC connections.

  Each connection is supervised by a ConnectionSupervisor which manages
  the Connection process.

  ## Configuration

  Global connection limit configured via application environment:

      config :quichex, max_connections: 10_000

  ## Process Tree

      ConnectionRegistry [DynamicSupervisor]
      ├─ ConnectionSupervisor (per connection)
      │   └─ Connection
      ├─ ConnectionSupervisor (per connection)
      ...

  ## Usage

      {:ok, conn} = Quichex.ConnectionRegistry.start_connection(
        host: "example.com",
        port: 443,
        config: config
      )

  ## Limits

  When `max_connections` limit is reached, `start_connection/1` returns
  `{:error, :connection_limit_reached}`.
  """

  use DynamicSupervisor
  require Logger

  @doc """
  Starts the ConnectionRegistry.

  This is called automatically by the application supervisor.
  """
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts a new connection under supervision.

  Returns `{:ok, conn_pid}` where `conn_pid` is the Connection process PID.
  This PID can be used with all `Quichex.Connection` functions.

  ## Options

  Same as `Quichex.Connection.connect/1`.

  ## Returns

    * `{:ok, pid}` - Connection process PID
    * `{:error, :connection_limit_reached}` - Max connections exceeded
    * `{:error, reason}` - Other errors

  ## Examples

      config = Quichex.Config.new!()
        |> Quichex.Config.verify_peer(false)

      {:ok, conn} = Quichex.ConnectionRegistry.start_connection(
        host: "localhost",
        port: 4433,
        config: config
      )

      # Use conn with all Connection functions
      Quichex.Connection.wait_connected(conn)
  """
  @spec start_connection(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_connection(opts) do
    # Inject the caller's PID as controlling_process (for handler messages)
    controlling_process = self()

    opts_with_defaults =
      opts
      |> Keyword.put_new(:controlling_process, controlling_process)
      |> Keyword.put_new(:handler, Quichex.Handler.Default)
      |> Keyword.update(:handler_opts, [controlling_process: controlling_process], fn handler_opts ->
        Keyword.put_new(handler_opts, :controlling_process, controlling_process)
      end)

    # Start ConnectionSupervisor (which starts Connection)
    case DynamicSupervisor.start_child(__MODULE__, {Quichex.ConnectionSupervisor, opts_with_defaults}) do
      {:ok, conn_sup_pid} ->
        # Get the Connection PID from ConnectionSupervisor children
        case get_connection_pid(conn_sup_pid) do
          {:ok, conn_pid} ->
            {:ok, conn_pid}

          {:error, reason} ->
            Logger.error(
              "Failed to get Connection PID from ConnectionSupervisor: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, :max_children} ->
        {:error, :connection_limit_reached}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(_init_arg) do
    max_connections = Application.get_env(:quichex, :max_connections, 10_000)

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: max_connections
    )
  end

  # Get Connection PID from ConnectionSupervisor
  defp get_connection_pid(conn_sup_pid) do
    # ConnectionSupervisor has 1 child: Connection
    # Find the Connection process by its id
    Quichex.ConnectionSupervisor.connection_pid(conn_sup_pid)
  end
end
