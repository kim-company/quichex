defmodule Quichex.Test.ListenerHelpers do
  @moduledoc """
  Helper functions for Listener integration tests.

  Provides utilities for:
  - Creating server and client configurations
  - Starting listeners and clients
  - Cleaning up resources
  """

  alias Quichex.{Config, Listener, Connection}

  @doc """
  Creates a server configuration with certificates from priv folder.

  Uses the self-signed certificates in priv/cert.crt and priv/cert.key.
  """
  def create_server_config do
    cert_path = Path.join(:code.priv_dir(:quichex), "cert.crt")
    key_path = Path.join(:code.priv_dir(:quichex), "cert.key")

    Config.new!()
    |> Config.set_application_protos(["hq-interop"])
    |> Config.load_cert_chain_from_pem_file(cert_path)
    |> Config.load_priv_key_from_pem_file(key_path)
    |> Config.set_max_idle_timeout(5_000)
    |> Config.set_initial_max_data(10_000_000)
    |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
    |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)
    |> Config.set_initial_max_streams_bidi(100)
    |> Config.set_initial_max_streams_uni(100)
  end

  @doc """
  Creates a client configuration for testing.

  Sets verify_peer: false to accept self-signed certificates.
  """
  def create_client_config do
    Config.new!()
    |> Config.set_application_protos(["hq-interop"])
    |> Config.verify_peer(false)
    |> Config.set_max_idle_timeout(5_000)
    |> Config.set_initial_max_data(10_000_000)
    |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
    |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)
    |> Config.set_initial_max_streams_bidi(100)
    |> Config.set_initial_max_streams_uni(100)
  end

  @doc """
  Starts a listener on a random available port.

  Returns the listener spec for use with start_link_supervised!/2.

  ## Options

  - `:port` - Port to bind to (default: 0 for random)
  - `:handler` - Handler module (required)
  - `:handler_opts` - Options for handler init (default: [])
  - `:config` - Server config (default: create_server_config())

  ## Example

      listener_spec = ListenerHelpers.listener_spec(
        handler: EchoHandler,
        handler_opts: [pid: self()]
      )
      listener = start_link_supervised!(listener_spec)
      {:ok, port} = Listener.get_local_addr(listener)
  """
  def listener_spec(opts \\ []) do
    handler = Keyword.fetch!(opts, :handler)
    port = Keyword.get(opts, :port, 0)
    handler_opts = Keyword.get(opts, :handler_opts, [])
    config = Keyword.get(opts, :config, create_server_config())

    {Listener,
     [
       port: port,
       config: config,
       handler: handler,
       handler_opts: handler_opts
     ]}
  end

  @doc """
  Starts a client connection to the given port.

  Returns {:ok, conn_pid} or {:error, reason}.

  ## Options

  - `:host` - Host to connect to (default: "127.0.0.1")
  - `:config` - Client config (default: create_client_config())
  - `:handler` - Handler module (default: Handler.Default)
  - `:handler_opts` - Options for handler init (default: [])

  ## Example

      {:ok, client} = ListenerHelpers.start_client(port)
  """
  def start_client(port, opts \\ []) do
    host = Keyword.get(opts, :host, "127.0.0.1")
    config = Keyword.get(opts, :config, create_client_config())
    handler = Keyword.get(opts, :handler, Quichex.Handler.Default)
    handler_opts = Keyword.get(opts, :handler_opts, [])

    Connection.start_link(
      host: host,
      port: port,
      config: config,
      handler: handler,
      handler_opts: handler_opts
    )
  end

  @doc """
  Waits for a connection to be established.

  Polls connection status with timeout.
  """
  def wait_for_connection(conn_pid, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop = fn wait_fn ->
      case Connection.is_established?(conn_pid) do
        true ->
          :ok

        false ->
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(10)
            wait_fn.(wait_fn)
          else
            {:error, :timeout}
          end
      end
    end

    wait_loop.(wait_loop)
  end

  @doc """
  Waits for stream data to be received.

  Expects a message of the form `{:quic_stream_data, ^conn_pid, ^stream_id, data, fin}`
  """
  def wait_for_stream_data(conn_pid, stream_id, timeout \\ 5_000) do
    receive do
      {:quic_stream_data, ^conn_pid, ^stream_id, data, fin} ->
        {:ok, data, fin}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  @doc """
  Waits for any stream data to be received on the connection.

  Returns {:ok, stream_id, data, fin} or {:error, :timeout}.
  """
  def wait_for_any_stream_data(conn_pid, timeout \\ 5_000) do
    receive do
      {:quic_stream_data, ^conn_pid, stream_id, data, fin} ->
        {:ok, stream_id, data, fin}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  @doc """
  Stops a client connection gracefully.
  """
  def stop_client(conn_pid) do
    if Process.alive?(conn_pid) do
      Connection.close(conn_pid)
      # Wait a bit for graceful shutdown
      Process.sleep(50)

      # Force kill if still alive
      if Process.alive?(conn_pid) do
        Process.exit(conn_pid, :kill)
      end
    end

    :ok
  end
end
