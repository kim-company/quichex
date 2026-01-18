defmodule Quichex.Native.Nif do
  @moduledoc """
  Internal Rustler bindings. Prefer `Quichex.Native` for public usage.
  """

  use Rustler,
    otp_app: :quichex,
    crate: :quichex_nif

  @type config :: reference()
  @type connection :: reference()
  @type stream_id :: non_neg_integer()
  @type reason :: String.t()
  @type quic_binary :: binary()

  ## Config NIFs
  @spec config_new(non_neg_integer()) :: {:ok, config()} | {:error, reason()}
  def config_new(_version), do: error()

  @spec config_set_application_protos(config(), [quic_binary()]) :: :ok | {:error, reason()}
  def config_set_application_protos(_config, _protos), do: error()

  @spec config_set_max_idle_timeout(config(), non_neg_integer()) :: :ok | {:error, reason()}
  def config_set_max_idle_timeout(_config, _millis), do: error()

  @spec config_set_initial_max_streams_bidi(config(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_set_initial_max_streams_bidi(_config, _value), do: error()

  @spec config_set_initial_max_streams_uni(config(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_set_initial_max_streams_uni(_config, _value), do: error()

  @spec config_set_initial_max_data(config(), non_neg_integer()) :: :ok | {:error, reason()}
  def config_set_initial_max_data(_config, _value), do: error()

  @spec config_set_initial_max_stream_data_bidi_local(config(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_set_initial_max_stream_data_bidi_local(_config, _value), do: error()

  @spec config_set_initial_max_stream_data_bidi_remote(config(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_set_initial_max_stream_data_bidi_remote(_config, _value), do: error()

  @spec config_set_initial_max_stream_data_uni(config(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_set_initial_max_stream_data_uni(_config, _value), do: error()

  @spec config_verify_peer(config(), boolean()) :: :ok | {:error, reason()}
  def config_verify_peer(_config, _verify), do: error()

  @spec config_load_cert_chain_from_pem_file(config(), String.t()) :: :ok | {:error, reason()}
  def config_load_cert_chain_from_pem_file(_config, _path), do: error()

  @spec config_load_priv_key_from_pem_file(config(), String.t()) :: :ok | {:error, reason()}
  def config_load_priv_key_from_pem_file(_config, _path), do: error()

  @spec config_load_verify_locations_from_file(config(), String.t()) :: :ok | {:error, reason()}
  def config_load_verify_locations_from_file(_config, _path), do: error()

  @spec config_load_verify_locations_from_directory(config(), String.t()) ::
          :ok | {:error, reason()}
  def config_load_verify_locations_from_directory(_config, _path), do: error()

  @spec config_set_cc_algorithm(config(), String.t()) :: :ok | {:error, reason()}
  def config_set_cc_algorithm(_config, _algo), do: error()

  @spec config_enable_dgram(config(), boolean(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_enable_dgram(_config, _enabled, _recv_queue_len, _send_queue_len), do: error()

  @spec config_set_max_recv_udp_payload_size(config(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_set_max_recv_udp_payload_size(_config, _size), do: error()

  @spec config_set_max_send_udp_payload_size(config(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_set_max_send_udp_payload_size(_config, _size), do: error()

  @spec config_set_disable_active_migration(config(), boolean()) :: :ok | {:error, reason()}
  def config_set_disable_active_migration(_config, _disable), do: error()

  @spec config_grease(config(), boolean()) :: :ok | {:error, reason()}
  def config_grease(_config, _enable), do: error()

  @spec config_discover_pmtu(config(), boolean()) :: :ok | {:error, reason()}
  def config_discover_pmtu(_config, _enable), do: error()

  @spec config_log_keys(config()) :: :ok | {:error, reason()}
  def config_log_keys(_config), do: error()

  @spec config_enable_early_data(config()) :: :ok | {:error, reason()}
  def config_enable_early_data(_config), do: error()

  @spec config_set_max_amplification_factor(config(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_set_max_amplification_factor(_config, _value), do: error()

  @spec config_set_ack_delay_exponent(config(), non_neg_integer()) :: :ok | {:error, reason()}
  def config_set_ack_delay_exponent(_config, _value), do: error()

  @spec config_set_max_ack_delay(config(), non_neg_integer()) :: :ok | {:error, reason()}
  def config_set_max_ack_delay(_config, _value), do: error()

  @spec config_set_initial_congestion_window_packets(config(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_set_initial_congestion_window_packets(_config, _value), do: error()

  @spec config_enable_hystart(config(), boolean()) :: :ok | {:error, reason()}
  def config_enable_hystart(_config, _enable), do: error()

  @spec config_enable_pacing(config(), boolean()) :: :ok | {:error, reason()}
  def config_enable_pacing(_config, _enable), do: error()

  @spec config_set_max_pacing_rate(config(), non_neg_integer()) :: :ok | {:error, reason()}
  def config_set_max_pacing_rate(_config, _value), do: error()

  @spec config_set_max_connection_window(config(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_set_max_connection_window(_config, _value), do: error()

  @spec config_set_max_stream_window(config(), non_neg_integer()) :: :ok | {:error, reason()}
  def config_set_max_stream_window(_config, _value), do: error()

  @spec config_set_active_connection_id_limit(config(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def config_set_active_connection_id_limit(_config, _value), do: error()

  @spec config_set_stateless_reset_token(config(), quic_binary()) :: :ok | {:error, reason()}
  def config_set_stateless_reset_token(_config, _token), do: error()

  @spec config_set_disable_dcid_reuse(config(), boolean()) :: :ok | {:error, reason()}
  def config_set_disable_dcid_reuse(_config, _disable), do: error()

  @spec config_set_ticket_key(config(), quic_binary()) :: :ok | {:error, reason()}
  def config_set_ticket_key(_config, _key), do: error()

  ## Connection lifecycle NIFs
  @spec connection_new_client(
          quic_binary(),
          String.t() | nil,
          quic_binary(),
          quic_binary(),
          config(),
          non_neg_integer()
        ) :: {:ok, connection()} | {:error, reason()}
  def connection_new_client(
        _scid,
        _server_name,
        _local_addr,
        _peer_addr,
        _config,
        _stream_recv_buffer_size
      ),
      do: error()

  @spec connection_new_server(
          quic_binary(),
          quic_binary() | nil,
          quic_binary(),
          quic_binary(),
          config(),
          non_neg_integer()
        ) :: {:ok, connection()} | {:error, reason()}
  def connection_new_server(
        _scid,
        _odcid,
        _local_addr,
        _peer_addr,
        _config,
        _stream_recv_buffer_size
      ),
      do: error()

  @spec connection_recv(connection(), quic_binary(), map()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  def connection_recv(_conn, _packet, _recv_info), do: error()

  @spec connection_send(connection()) :: {:ok, {quic_binary(), map()}} | {:error, reason()}
  def connection_send(_conn), do: error()

  @spec connection_timeout(connection()) :: {:ok, non_neg_integer()} | {:error, reason()}
  def connection_timeout(_conn), do: error()

  @spec connection_on_timeout(connection()) :: :ok | {:error, reason()}
  def connection_on_timeout(_conn), do: error()

  @spec connection_is_established(connection()) :: {:ok, boolean()} | {:error, reason()}
  def connection_is_established(_conn), do: error()

  @spec connection_is_closed(connection()) :: {:ok, boolean()} | {:error, reason()}
  def connection_is_closed(_conn), do: error()

  @spec connection_is_draining(connection()) :: {:ok, boolean()} | {:error, reason()}
  def connection_is_draining(_conn), do: error()

  @spec connection_is_resumed(connection()) :: {:ok, boolean()} | {:error, reason()}
  def connection_is_resumed(_conn), do: error()

  @spec connection_is_timed_out(connection()) :: {:ok, boolean()} | {:error, reason()}
  def connection_is_timed_out(_conn), do: error()

  @spec connection_is_server(connection()) :: {:ok, boolean()} | {:error, reason()}
  def connection_is_server(_conn), do: error()

  @spec connection_close(connection(), boolean(), non_neg_integer(), quic_binary()) ::
          :ok | {:error, reason()}
  def connection_close(_conn, _app, _err, _reason), do: error()

  @spec connection_trace_id(connection()) :: {:ok, String.t()} | {:error, reason()}
  def connection_trace_id(_conn), do: error()

  @spec connection_source_id(connection()) :: {:ok, quic_binary()} | {:error, reason()}
  def connection_source_id(_conn), do: error()

  @spec connection_destination_id(connection()) :: {:ok, quic_binary()} | {:error, reason()}
  def connection_destination_id(_conn), do: error()

  @spec connection_application_proto(connection()) :: {:ok, quic_binary()} | {:error, reason()}
  def connection_application_proto(_conn), do: error()

  @spec connection_peer_cert(connection()) :: {:ok, quic_binary() | nil} | {:error, reason()}
  def connection_peer_cert(_conn), do: error()

  @spec connection_peer_error(connection()) ::
          {:ok, Quichex.Native.ConnectionError.t() | nil} | {:error, reason()}
  def connection_peer_error(_conn), do: error()

  @spec connection_local_error(connection()) ::
          {:ok, Quichex.Native.ConnectionError.t() | nil} | {:error, reason()}
  def connection_local_error(_conn), do: error()

  @spec connection_stats(connection()) ::
          {:ok, Quichex.Native.ConnectionStats.t()} | {:error, reason()}
  def connection_stats(_conn), do: error()

  @spec connection_peer_transport_params(connection()) ::
          {:ok, Quichex.Native.TransportParams.t() | nil} | {:error, reason()}
  def connection_peer_transport_params(_conn), do: error()

  @spec connection_is_in_early_data(connection()) :: {:ok, boolean()} | {:error, reason()}
  def connection_is_in_early_data(_conn), do: error()

  @spec connection_set_keylog_path(connection(), String.t()) :: :ok | {:error, reason()}
  def connection_set_keylog_path(_conn, _path), do: error()

  @spec connection_set_session(connection(), quic_binary()) :: :ok | {:error, reason()}
  def connection_set_session(_conn, _data), do: error()

  @spec connection_session(connection()) :: {:ok, quic_binary() | nil} | {:error, reason()}
  def connection_session(_conn), do: error()

  @spec connection_server_name(connection()) :: {:ok, String.t() | nil} | {:error, reason()}
  def connection_server_name(_conn), do: error()

  ## Stream helpers
  @spec connection_stream_send(connection(), stream_id(), quic_binary(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  def connection_stream_send(_conn, _stream_id, _data, _fin), do: error()

  @spec connection_stream_recv(connection(), stream_id(), non_neg_integer()) ::
          {:ok, {quic_binary(), boolean()}} | {:error, reason()}
  def connection_stream_recv(_conn, _stream_id, _max_len), do: error()

  @spec connection_readable_streams(connection()) :: {:ok, [stream_id()]} | {:error, reason()}
  def connection_readable_streams(_conn), do: error()

  @spec connection_writable_streams(connection()) :: {:ok, [stream_id()]} | {:error, reason()}
  def connection_writable_streams(_conn), do: error()

  @spec connection_stream_finished(connection(), stream_id()) ::
          {:ok, boolean()} | {:error, reason()}
  def connection_stream_finished(_conn, _stream_id), do: error()

  @spec connection_stream_shutdown(connection(), stream_id(), String.t(), non_neg_integer()) ::
          :ok | {:error, reason()}
  def connection_stream_shutdown(_conn, _stream_id, _direction, _error_code), do: error()

  ## Datagram helpers
  @spec connection_dgram_max_writable_len(connection()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  def connection_dgram_max_writable_len(_conn), do: error()

  @spec connection_dgram_recv_queue_len(connection()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  def connection_dgram_recv_queue_len(_conn), do: error()

  @spec connection_dgram_recv_queue_byte_size(connection()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  def connection_dgram_recv_queue_byte_size(_conn), do: error()

  @spec connection_dgram_send_queue_byte_size(connection()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  def connection_dgram_send_queue_byte_size(_conn), do: error()

  @spec connection_dgram_send_queue_len(connection()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  def connection_dgram_send_queue_len(_conn), do: error()

  @spec connection_dgram_send(connection(), quic_binary()) ::
          {:ok, non_neg_integer()} | {:error, reason()}
  def connection_dgram_send(_conn, _payload), do: error()

  @spec connection_dgram_recv(connection(), non_neg_integer()) ::
          {:ok, quic_binary()} | {:error, reason()}
  def connection_dgram_recv(_conn, _max_len), do: error()

  ## Packet helpers
  @spec header_info(quic_binary(), non_neg_integer()) ::
          {:ok, Quichex.Native.PacketHeader.t()} | {:error, reason()}
  def header_info(_packet, _dcid_len), do: error()

  @spec version_negotiate(quic_binary(), quic_binary()) ::
          {:ok, quic_binary()} | {:error, reason()}
  def version_negotiate(_scid, _dcid), do: error()

  @spec retry(quic_binary(), quic_binary(), quic_binary(), quic_binary(), non_neg_integer()) ::
          {:ok, quic_binary()} | {:error, reason()}
  def retry(_scid, _dcid, _new_scid, _token, _version), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
