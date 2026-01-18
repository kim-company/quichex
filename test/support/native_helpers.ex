defmodule Quichex.Native.TestHelpers do
  @moduledoc """
  Convenience helpers for spinning up quiche client/server resources in tests.

  ```elixir
  alias Quichex.Native.TestHelpers

  {_, client} = TestHelpers.create_connection()
  {_, server} = TestHelpers.accept_connection()
  ```
  """

  alias Quichex.Native

  @default_protos ["hq-29"]
  @priv_dir Path.expand("../../priv", __DIR__)
  @cert_path Path.join(@priv_dir, "cert.crt")
  @key_path Path.join(@priv_dir, "cert.key")

  defguardp is_byte(value) when is_integer(value) and value >= 0 and value <= 255
  defguardp is_udp_port(value) when is_integer(value) and value >= 0 and value <= 65_535

  @type config :: term()
  @type connection :: term()
  @type options :: keyword()

  @doc "Create a client-side config mirroring `quiche::Config::new/1` defaults."
  @spec create_config(options()) :: config()
  def create_config(opts \\ []), do: build_config(:client, opts)

  @doc "Create a server-side config that also loads the repo's self-signed cert/key."
  @spec accept_config(options()) :: config()
  def accept_config(opts \\ []), do: build_config(:server, opts)

  @doc """
  Instantiate a client connection resource.

  Accepts optional `:local_port`, `:peer_port`, `:scid`, and TLS overrides.
  """
  @spec create_connection(options()) :: {config(), connection()}
  def create_connection(opts \\ []),
    do: build_connection(:client, opts, &Native.connection_new_client/6)

  @doc "Instantiate a server connection resource using `connection_new_server/6`."
  @spec accept_connection(options()) :: {config(), connection()}
  def accept_connection(opts \\ []),
    do: build_connection(:server, opts, &Native.connection_new_server/6)

  @doc "Encode an IPv4/UDP tuple into the binary format expected by the NIFs."
  @spec ipv4({0..255, 0..255, 0..255, 0..255}, 0..65_535) :: binary()
  def ipv4({a, b, c, d}, port)
      when is_byte(a) and is_byte(b) and is_byte(c) and is_byte(d) and is_udp_port(port) do
    <<a, b, c, d, port::16-big>>
  end

  @doc "Bubble up {:ok, value} tuples or raise on unexpected results."
  @spec ok!(term()) :: term()
  def ok!(:ok), do: :ok
  def ok!({:ok, {}}), do: :ok
  def ok!({:ok, value}), do: value
  def ok!(other), do: other

  defp build_config(role, opts) when role in [:client, :server] do
    version = Keyword.get(opts, :version, 0)
    protos = Keyword.get(opts, :protos, @default_protos)

    config =
      Native.config_new(version)
      |> Native.config_set_application_protos(protos)
      |> Native.config_verify_peer(false)
      |> Native.config_enable_dgram(true, 32, 32)
      |> Native.config_set_max_recv_udp_payload_size(1350)
      |> Native.config_set_max_send_udp_payload_size(1350)
      |> Native.config_set_initial_max_data(1_000_000)
      |> Native.config_set_initial_max_stream_data_bidi_local(1_000_000)
      |> Native.config_set_initial_max_stream_data_bidi_remote(1_000_000)
      |> Native.config_set_initial_max_stream_data_uni(1_000_000)
      |> Native.config_set_initial_max_streams_bidi(32)
      |> Native.config_set_initial_max_streams_uni(32)
      |> Native.config_set_disable_active_migration(true)

    case role do
      :client ->
        config

      :server ->
        cert = Keyword.get(opts, :cert, @cert_path)
        key = Keyword.get(opts, :key, @key_path)

        config
        |> Native.config_load_cert_chain_from_pem_file(cert)
        |> Native.config_load_priv_key_from_pem_file(key)
    end
  end

  defp build_connection(role, opts, nif_fun) when role in [:client, :server] do
    config =
      Keyword.get_lazy(opts, :config, fn ->
        case role do
          :client -> create_config(opts)
          :server -> accept_config(opts)
        end
      end)

    scid = Keyword.get_lazy(opts, :scid, fn -> :crypto.strong_rand_bytes(16) end)
    local_port = Keyword.get(opts, :local_port, default_local_port(role))
    peer_port = Keyword.get(opts, :peer_port, default_peer_port(role))

    local_addr = ipv4({127, 0, 0, 1}, local_port)
    peer_addr = ipv4({127, 0, 0, 1}, peer_port)

    args =
      case role do
        :client ->
          [
            scid,
            Keyword.get(opts, :server_name),
            local_addr,
            peer_addr,
            config,
            Keyword.get(opts, :stream_buffer, 4096)
          ]

        :server ->
          [
            scid,
            Keyword.get(opts, :odcid),
            local_addr,
            peer_addr,
            config,
            Keyword.get(opts, :stream_buffer, 4096)
          ]
      end

    {:ok, conn} = apply(nif_fun, args)
    {config, conn}
  end

  defp default_local_port(:client), do: 4000
  defp default_local_port(:server), do: 5000
  defp default_peer_port(:client), do: 5000
  defp default_peer_port(:server), do: 4000
end
