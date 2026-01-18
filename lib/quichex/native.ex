defmodule Quichex.Native do
  @moduledoc """
  Thin Rustler bindings to the [`quiche`](https://github.com/cloudflare/quiche)
  QUIC implementation.

  These functions provide a direct bridge to the native library. Most NIFs
  return `{:ok, term}` / `{:error, reason}` tuples, while config setters return
  the updated config and raise `Quichex.Native.ConfigError` on failures.
  """

  alias Quichex.Native.{ConfigError, Nif}

  @type config :: reference()
  @type connection :: reference()
  @type stream_id :: non_neg_integer()
  @type reason :: String.t()
  @type quic_binary :: binary()

  @spec config_new(non_neg_integer()) :: config()
  def config_new(version) do
    config_ok!("config_new", Nif.config_new(version))
  end

  @spec config_set_application_protos(config(), [quic_binary()]) :: config()
  def config_set_application_protos(config, protos) do
    config_ok!("config_set_application_protos", Nif.config_set_application_protos(config, protos), config)
  end

  @spec config_set_max_idle_timeout(config(), non_neg_integer()) :: config()
  def config_set_max_idle_timeout(config, millis) do
    config_ok!("config_set_max_idle_timeout", Nif.config_set_max_idle_timeout(config, millis), config)
  end

  @spec config_set_initial_max_streams_bidi(config(), non_neg_integer()) :: config()
  def config_set_initial_max_streams_bidi(config, value) do
    config_ok!(
      "config_set_initial_max_streams_bidi",
      Nif.config_set_initial_max_streams_bidi(config, value),
      config
    )
  end

  @spec config_set_initial_max_streams_uni(config(), non_neg_integer()) :: config()
  def config_set_initial_max_streams_uni(config, value) do
    config_ok!(
      "config_set_initial_max_streams_uni",
      Nif.config_set_initial_max_streams_uni(config, value),
      config
    )
  end

  @spec config_set_initial_max_data(config(), non_neg_integer()) :: config()
  def config_set_initial_max_data(config, value) do
    config_ok!("config_set_initial_max_data", Nif.config_set_initial_max_data(config, value), config)
  end

  @spec config_set_initial_max_stream_data_bidi_local(config(), non_neg_integer()) :: config()
  def config_set_initial_max_stream_data_bidi_local(config, value) do
    config_ok!(
      "config_set_initial_max_stream_data_bidi_local",
      Nif.config_set_initial_max_stream_data_bidi_local(config, value),
      config
    )
  end

  @spec config_set_initial_max_stream_data_bidi_remote(config(), non_neg_integer()) :: config()
  def config_set_initial_max_stream_data_bidi_remote(config, value) do
    config_ok!(
      "config_set_initial_max_stream_data_bidi_remote",
      Nif.config_set_initial_max_stream_data_bidi_remote(config, value),
      config
    )
  end

  @spec config_set_initial_max_stream_data_uni(config(), non_neg_integer()) :: config()
  def config_set_initial_max_stream_data_uni(config, value) do
    config_ok!(
      "config_set_initial_max_stream_data_uni",
      Nif.config_set_initial_max_stream_data_uni(config, value),
      config
    )
  end

  @spec config_verify_peer(config(), boolean()) :: config()
  def config_verify_peer(config, verify) do
    config_ok!("config_verify_peer", Nif.config_verify_peer(config, verify), config)
  end

  @spec config_load_cert_chain_from_pem_file(config(), String.t()) :: config()
  def config_load_cert_chain_from_pem_file(config, path) do
    config_ok!(
      "config_load_cert_chain_from_pem_file",
      Nif.config_load_cert_chain_from_pem_file(config, path),
      config
    )
  end

  @spec config_load_priv_key_from_pem_file(config(), String.t()) :: config()
  def config_load_priv_key_from_pem_file(config, path) do
    config_ok!(
      "config_load_priv_key_from_pem_file",
      Nif.config_load_priv_key_from_pem_file(config, path),
      config
    )
  end

  @spec config_load_verify_locations_from_file(config(), String.t()) :: config()
  def config_load_verify_locations_from_file(config, path) do
    config_ok!(
      "config_load_verify_locations_from_file",
      Nif.config_load_verify_locations_from_file(config, path),
      config
    )
  end

  @spec config_load_verify_locations_from_directory(config(), String.t()) :: config()
  def config_load_verify_locations_from_directory(config, path) do
    config_ok!(
      "config_load_verify_locations_from_directory",
      Nif.config_load_verify_locations_from_directory(config, path),
      config
    )
  end

  @spec config_set_cc_algorithm(config(), String.t()) :: config()
  def config_set_cc_algorithm(config, algo) do
    config_ok!("config_set_cc_algorithm", Nif.config_set_cc_algorithm(config, algo), config)
  end

  @spec config_enable_dgram(config(), boolean(), non_neg_integer(), non_neg_integer()) :: config()
  def config_enable_dgram(config, enabled, recv_queue_len, send_queue_len) do
    config_ok!(
      "config_enable_dgram",
      Nif.config_enable_dgram(config, enabled, recv_queue_len, send_queue_len),
      config
    )
  end

  @spec config_set_max_recv_udp_payload_size(config(), non_neg_integer()) :: config()
  def config_set_max_recv_udp_payload_size(config, size) do
    config_ok!(
      "config_set_max_recv_udp_payload_size",
      Nif.config_set_max_recv_udp_payload_size(config, size),
      config
    )
  end

  @spec config_set_max_send_udp_payload_size(config(), non_neg_integer()) :: config()
  def config_set_max_send_udp_payload_size(config, size) do
    config_ok!(
      "config_set_max_send_udp_payload_size",
      Nif.config_set_max_send_udp_payload_size(config, size),
      config
    )
  end

  @spec config_set_disable_active_migration(config(), boolean()) :: config()
  def config_set_disable_active_migration(config, disable) do
    config_ok!(
      "config_set_disable_active_migration",
      Nif.config_set_disable_active_migration(config, disable),
      config
    )
  end

  @spec config_grease(config(), boolean()) :: config()
  def config_grease(config, enable) do
    config_ok!("config_grease", Nif.config_grease(config, enable), config)
  end

  @spec config_discover_pmtu(config(), boolean()) :: config()
  def config_discover_pmtu(config, enable) do
    config_ok!("config_discover_pmtu", Nif.config_discover_pmtu(config, enable), config)
  end

  @spec config_log_keys(config()) :: config()
  def config_log_keys(config) do
    config_ok!("config_log_keys", Nif.config_log_keys(config), config)
  end

  @spec config_enable_early_data(config()) :: config()
  def config_enable_early_data(config) do
    config_ok!("config_enable_early_data", Nif.config_enable_early_data(config), config)
  end

  @spec config_set_max_amplification_factor(config(), non_neg_integer()) :: config()
  def config_set_max_amplification_factor(config, value) do
    config_ok!(
      "config_set_max_amplification_factor",
      Nif.config_set_max_amplification_factor(config, value),
      config
    )
  end

  @spec config_set_ack_delay_exponent(config(), non_neg_integer()) :: config()
  def config_set_ack_delay_exponent(config, value) do
    config_ok!(
      "config_set_ack_delay_exponent",
      Nif.config_set_ack_delay_exponent(config, value),
      config
    )
  end

  @spec config_set_max_ack_delay(config(), non_neg_integer()) :: config()
  def config_set_max_ack_delay(config, value) do
    config_ok!("config_set_max_ack_delay", Nif.config_set_max_ack_delay(config, value), config)
  end

  @spec config_set_initial_congestion_window_packets(config(), non_neg_integer()) :: config()
  def config_set_initial_congestion_window_packets(config, value) do
    config_ok!(
      "config_set_initial_congestion_window_packets",
      Nif.config_set_initial_congestion_window_packets(config, value),
      config
    )
  end

  @spec config_enable_hystart(config(), boolean()) :: config()
  def config_enable_hystart(config, enable) do
    config_ok!("config_enable_hystart", Nif.config_enable_hystart(config, enable), config)
  end

  @spec config_enable_pacing(config(), boolean()) :: config()
  def config_enable_pacing(config, enable) do
    config_ok!("config_enable_pacing", Nif.config_enable_pacing(config, enable), config)
  end

  @spec config_set_max_pacing_rate(config(), non_neg_integer()) :: config()
  def config_set_max_pacing_rate(config, value) do
    config_ok!("config_set_max_pacing_rate", Nif.config_set_max_pacing_rate(config, value), config)
  end

  @spec config_set_max_connection_window(config(), non_neg_integer()) :: config()
  def config_set_max_connection_window(config, value) do
    config_ok!(
      "config_set_max_connection_window",
      Nif.config_set_max_connection_window(config, value),
      config
    )
  end

  @spec config_set_max_stream_window(config(), non_neg_integer()) :: config()
  def config_set_max_stream_window(config, value) do
    config_ok!("config_set_max_stream_window", Nif.config_set_max_stream_window(config, value), config)
  end

  @spec config_set_active_connection_id_limit(config(), non_neg_integer()) :: config()
  def config_set_active_connection_id_limit(config, value) do
    config_ok!(
      "config_set_active_connection_id_limit",
      Nif.config_set_active_connection_id_limit(config, value),
      config
    )
  end

  @spec config_set_stateless_reset_token(config(), quic_binary()) :: config()
  def config_set_stateless_reset_token(config, token) do
    config_ok!(
      "config_set_stateless_reset_token",
      Nif.config_set_stateless_reset_token(config, token),
      config
    )
  end

  @spec config_set_disable_dcid_reuse(config(), boolean()) :: config()
  def config_set_disable_dcid_reuse(config, disable) do
    config_ok!(
      "config_set_disable_dcid_reuse",
      Nif.config_set_disable_dcid_reuse(config, disable),
      config
    )
  end

  @spec config_set_ticket_key(config(), quic_binary()) :: config()
  def config_set_ticket_key(config, key) do
    config_ok!("config_set_ticket_key", Nif.config_set_ticket_key(config, key), config)
  end

  defp config_ok!(function, result, config \\ nil) do
    case result do
      :ok -> config
      {:ok, {}} -> config
      {:ok, value} -> value
      {:error, reason} ->
        raise ConfigError,
          message: "#{function} failed: #{reason}",
          reason: reason,
          function: function

      other ->
        raise ConfigError,
          message: "#{function} failed: #{inspect(other)}",
          reason: inspect(other),
          function: function
    end
  end

  # Delegate non-config functions to the NIF module.
  Code.ensure_compiled!(Nif)

  for {name, arity} <- Nif.__info__(:functions),
      name not in [:__info__, :module_info, :rustler_init],
      not String.starts_with?(Atom.to_string(name), "config_") do
    args = Macro.generate_arguments(arity, __MODULE__)
    defdelegate unquote(name)(unquote_splicing(args)), to: Nif
  end
end
