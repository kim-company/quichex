defmodule Quichex.Native.TestHelpers do
  @moduledoc false

  alias Quichex.Native

  @default_protos ["hq-29"]
  @priv_dir Path.expand("../../priv", __DIR__)
  @cert_path Path.join(@priv_dir, "cert.crt")
  @key_path Path.join(@priv_dir, "cert.key")

  def create_config(opts \\ []), do: build_config(:client, opts)
  def accept_config(opts \\ []), do: build_config(:server, opts)

  def create_connection(opts \\ []),
    do: build_connection(:client, opts, &Native.connection_new_client/6)

  def accept_connection(opts \\ []),
    do: build_connection(:server, opts, &Native.connection_new_server/6)

  def ipv4({a, b, c, d}, port) do
    <<a, b, c, d, port::16-big>>
  end

  def ok!(:ok), do: :ok
  def ok!({:ok, {}}), do: :ok
  def ok!({:ok, value}), do: value
  def ok!(other), do: other

  defp build_config(role, opts) do
    version = Keyword.get(opts, :version, 0)
    {:ok, config} = Native.config_new(version)

    protos = Keyword.get(opts, :protos, @default_protos)
    ok!(Native.config_set_application_protos(config, protos))
    ok!(Native.config_verify_peer(config, false))
    ok!(Native.config_enable_dgram(config, true, 32, 32))
    ok!(Native.config_set_max_recv_udp_payload_size(config, 1350))
    ok!(Native.config_set_max_send_udp_payload_size(config, 1350))
    ok!(Native.config_set_initial_max_data(config, 1_000_000))
    ok!(Native.config_set_initial_max_stream_data_bidi_local(config, 1_000_000))
    ok!(Native.config_set_initial_max_stream_data_bidi_remote(config, 1_000_000))
    ok!(Native.config_set_initial_max_stream_data_uni(config, 1_000_000))
    ok!(Native.config_set_initial_max_streams_bidi(config, 32))
    ok!(Native.config_set_initial_max_streams_uni(config, 32))
    ok!(Native.config_set_disable_active_migration(config, true))

    case role do
      :client ->
        config

      :server ->
        cert = Keyword.get(opts, :cert, @cert_path)
        key = Keyword.get(opts, :key, @key_path)
        ok!(Native.config_load_cert_chain_from_pem_file(config, cert))
        ok!(Native.config_load_priv_key_from_pem_file(config, key))
        config
    end
  end

  defp build_connection(role, opts, nif_fun) do
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
