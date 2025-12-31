defmodule Quichex do
  @moduledoc """
  Quichex - QUIC transport library for Elixir.

  Provides QUIC protocol support via Rustler bindings to cloudflare/quiche.
  Each QUIC connection runs in its own lightweight Elixir process, enabling
  massive concurrency with fault isolation.

  ## Features

  - Idiomatic Elixir API
  - Support for both client and server QUIC connections
  - Stream multiplexing (bidirectional and unidirectional)
  - Process-based concurrency model
  - Active/passive modes like :gen_tcp

  ## Quick Start

  See `Quichex.Connection` for client/server connection examples.
  See `Quichex.Config` for configuration options.
  """

  @version Mix.Project.config()[:version]

  @doc """
  Returns the Quichex version.
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Starts a new QUIC connection under supervision.

  This is the recommended way to create connections. The connection will be
  properly supervised and all resources will be cleaned up when it terminates.

  ## Options

  Same as `Quichex.Connection.connect/1`.

  ## Returns

    * `{:ok, pid}` - Connection process PID
    * `{:error, :connection_limit_reached}` - Max connections exceeded
    * `{:error, reason}` - Other errors

  ## Examples

      config = Quichex.Config.new!()
        |> Quichex.Config.set_application_protos(["http/1.1"])
        |> Quichex.Config.verify_peer(false)

      {:ok, conn} = Quichex.start_connection(
        host: "localhost",
        port: 4433,
        config: config
      )

      # Connection is automatically supervised
      Quichex.Connection.wait_connected(conn)

  """
  @spec start_connection(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_connection(opts) do
    # Extract metadata for telemetry
    host = Keyword.get(opts, :host, "unknown")
    port = Keyword.get(opts, :port, 0)
    mode = if Keyword.has_key?(opts, :listener_pid), do: :server, else: :client

    metadata = %{
      host: to_string(host),
      port: port,
      mode: mode
    }

    start_time = Quichex.Telemetry.start([:connection, :connect], metadata)

    case Quichex.ConnectionRegistry.start_connection(opts) do
      {:ok, conn_pid} = result ->
        Quichex.Telemetry.stop(
          [:connection, :connect],
          start_time,
          Map.put(metadata, :conn_pid, conn_pid)
        )

        result

      {:error, reason} = error ->
        Quichex.Telemetry.exception(
          [:connection, :connect],
          start_time,
          :error,
          reason,
          [],
          metadata
        )

        error
    end
  end

  @doc """
  Closes a supervised connection.

  Alias for `Quichex.Connection.close/2`.

  ## Arguments

    * `conn_pid` - Connection process PID
    * `opts` - Options (keyword list)

  ## Options

    * `:error_code` - QUIC error code (default: 0)
    * `:reason` - Human-readable reason (default: "")

  ## Returns

    * `:ok` - Connection closed successfully
  """
  @spec close_connection(pid(), keyword()) :: :ok
  def close_connection(conn_pid, opts \\ []) do
    Quichex.Connection.close(conn_pid, opts)
  end
end
