defmodule Quichex.Native do
  @moduledoc """
  Thin Rustler bindings to the [`quiche`](https://github.com/cloudflare/quiche)
  QUIC implementation.

  All functions are direct wrappers around the Rust NIFs and return `{:ok, term}`
  or `{:error, reason}` tuples straight from the native layer.
  """

  use Rustler,
    otp_app: :quichex,
    crate: :quichex_nif

  ## Misc helpers
  def add(_a, _b), do: error()

  ## Config NIFs
  def config_new(_version), do: error()
  def config_set_application_protos(_config, _protos), do: error()
  def config_set_max_idle_timeout(_config, _millis), do: error()
  def config_set_initial_max_streams_bidi(_config, _value), do: error()
  def config_set_initial_max_streams_uni(_config, _value), do: error()
  def config_set_initial_max_data(_config, _value), do: error()
  def config_set_initial_max_stream_data_bidi_local(_config, _value), do: error()
  def config_set_initial_max_stream_data_bidi_remote(_config, _value), do: error()
  def config_set_initial_max_stream_data_uni(_config, _value), do: error()
  def config_verify_peer(_config, _verify), do: error()
  def config_load_cert_chain_from_pem_file(_config, _path), do: error()
  def config_load_priv_key_from_pem_file(_config, _path), do: error()
  def config_load_verify_locations_from_file(_config, _path), do: error()
  def config_load_verify_locations_from_directory(_config, _path), do: error()
  def config_set_cc_algorithm(_config, _algo), do: error()
  def config_enable_dgram(_config, _enabled, _recv_queue_len, _send_queue_len), do: error()
  def config_set_max_recv_udp_payload_size(_config, _size), do: error()
  def config_set_max_send_udp_payload_size(_config, _size), do: error()
  def config_set_disable_active_migration(_config, _disable), do: error()
  def config_grease(_config, _enable), do: error()
  def config_discover_pmtu(_config, _enable), do: error()
  def config_log_keys(_config), do: error()
  def config_enable_early_data(_config), do: error()
  def config_set_max_amplification_factor(_config, _value), do: error()
  def config_set_ack_delay_exponent(_config, _value), do: error()
  def config_set_max_ack_delay(_config, _value), do: error()
  def config_set_initial_congestion_window_packets(_config, _value), do: error()
  def config_enable_hystart(_config, _enable), do: error()
  def config_enable_pacing(_config, _enable), do: error()
  def config_set_max_pacing_rate(_config, _value), do: error()
  def config_set_max_connection_window(_config, _value), do: error()
  def config_set_max_stream_window(_config, _value), do: error()
  def config_set_active_connection_id_limit(_config, _value), do: error()
  def config_set_stateless_reset_token(_config, _token), do: error()
  def config_set_disable_dcid_reuse(_config, _disable), do: error()
  def config_set_ticket_key(_config, _key), do: error()

  ## Connection lifecycle NIFs
  def connection_new_client(
        _scid,
        _server_name,
        _local_addr,
        _peer_addr,
        _config,
        _stream_recv_buffer_size
      ),
      do: error()

  def connection_new_server(
        _scid,
        _odcid,
        _local_addr,
        _peer_addr,
        _config,
        _stream_recv_buffer_size
      ),
      do: error()

  def connection_recv(_conn, _packet, _recv_info), do: error()
  def connection_send(_conn), do: error()
  def connection_timeout(_conn), do: error()
  def connection_on_timeout(_conn), do: error()
  def connection_is_established(_conn), do: error()
  def connection_is_closed(_conn), do: error()
  def connection_is_draining(_conn), do: error()
  def connection_is_resumed(_conn), do: error()
  def connection_is_timed_out(_conn), do: error()
  def connection_is_server(_conn), do: error()
  def connection_close(_conn, _app, _err, _reason), do: error()
  def connection_trace_id(_conn), do: error()
  def connection_source_id(_conn), do: error()
  def connection_destination_id(_conn), do: error()
  def connection_application_proto(_conn), do: error()
  def connection_peer_cert(_conn), do: error()
  def connection_peer_error(_conn), do: error()
  def connection_local_error(_conn), do: error()
  def connection_stats(_conn), do: error()
  def connection_peer_transport_params(_conn), do: error()
  def connection_is_in_early_data(_conn), do: error()
  def connection_set_keylog_path(_conn, _path), do: error()
  def connection_set_session(_conn, _data), do: error()
  def connection_session(_conn), do: error()
  def connection_server_name(_conn), do: error()

  ## Stream helpers
  def connection_stream_send(_conn, _stream_id, _data, _fin), do: error()
  def connection_stream_recv(_conn, _stream_id, _max_len), do: error()
  def connection_readable_streams(_conn), do: error()
  def connection_writable_streams(_conn), do: error()
  def connection_stream_finished(_conn, _stream_id), do: error()
  def connection_stream_shutdown(_conn, _stream_id, _direction, _error_code), do: error()

  ## Datagram helpers
  def connection_dgram_max_writable_len(_conn), do: error()
  def connection_dgram_recv_queue_len(_conn), do: error()
  def connection_dgram_recv_queue_byte_size(_conn), do: error()
  def connection_dgram_send_queue_len(_conn), do: error()
  def connection_dgram_send_queue_byte_size(_conn), do: error()
  def connection_dgram_send(_conn, _payload), do: error()
  def connection_dgram_recv(_conn, _max_len), do: error()

  ## Packet helpers
  def header_info(_packet, _dcid_len), do: error()
  def version_negotiate(_scid, _dcid), do: error()
  def retry(_scid, _dcid, _new_scid, _token, _version), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
