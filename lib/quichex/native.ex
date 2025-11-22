defmodule Quichex.Native do
  @moduledoc false
  # Internal module for Rustler NIFs

  use Rustler,
    otp_app: :quichex,
    crate: :quichex_nif

  # Example NIF
  def add(_a, _b), do: error()

  # Config NIFs
  def config_new(_version), do: error()
  def config_set_application_protos(_config, _protos), do: error()
  def config_set_max_idle_timeout(_config, _millis), do: error()
  def config_set_initial_max_streams_bidi(_config, _v), do: error()
  def config_set_initial_max_streams_uni(_config, _v), do: error()
  def config_set_initial_max_data(_config, _v), do: error()
  def config_set_initial_max_stream_data_bidi_local(_config, _v), do: error()
  def config_set_initial_max_stream_data_bidi_remote(_config, _v), do: error()
  def config_set_initial_max_stream_data_uni(_config, _v), do: error()
  def config_verify_peer(_config, _verify), do: error()
  def config_load_cert_chain_from_pem_file(_config, _path), do: error()
  def config_load_priv_key_from_pem_file(_config, _path), do: error()
  def config_load_verify_locations_from_file(_config, _path), do: error()
  def config_set_cc_algorithm(_config, _algo), do: error()
  def config_enable_dgram(_config, _enabled, _recv_queue_len, _send_queue_len), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
