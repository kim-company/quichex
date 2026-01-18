defmodule Quichex.H3 do
  @moduledoc """
  Low-level HTTP/3 bindings built on top of `Quichex.Native`.
  """

  import Bitwise

  alias Quichex.Native

  @type h3_config :: reference()
  @type h3_connection :: reference()
  @type connection :: reference()
  @type stream_id :: non_neg_integer()
  @type header :: {binary(), binary()}
  @type h3_event ::
          {:headers, [header()], boolean()}
          | :data
          | :finished
          | {:reset, non_neg_integer()}
          | {:goaway, non_neg_integer()}
          | :priority_update

  @spec config_new() :: h3_config()
  def config_new do
    unwrap_ok!("h3_config_new", Native.h3_config_new())
  end

  @spec config_set_max_field_section_size(h3_config(), non_neg_integer()) :: h3_config()
  def config_set_max_field_section_size(config, value) do
    unwrap_ok!("h3_config_set_max_field_section_size", Native.h3_config_set_max_field_section_size(config, value), config)
  end

  @spec config_set_qpack_max_table_capacity(h3_config(), non_neg_integer()) :: h3_config()
  def config_set_qpack_max_table_capacity(config, value) do
    unwrap_ok!("h3_config_set_qpack_max_table_capacity", Native.h3_config_set_qpack_max_table_capacity(config, value), config)
  end

  @spec config_set_qpack_blocked_streams(h3_config(), non_neg_integer()) :: h3_config()
  def config_set_qpack_blocked_streams(config, value) do
    unwrap_ok!("h3_config_set_qpack_blocked_streams", Native.h3_config_set_qpack_blocked_streams(config, value), config)
  end

  @spec config_enable_extended_connect(h3_config(), boolean()) :: h3_config()
  def config_enable_extended_connect(config, enabled) do
    unwrap_ok!("h3_config_enable_extended_connect", Native.h3_config_enable_extended_connect(config, enabled), config)
  end

  @spec config_set_additional_settings(h3_config(), [{non_neg_integer(), non_neg_integer()}]) ::
          h3_config()
  def config_set_additional_settings(config, settings) do
    unwrap_ok!("h3_config_set_additional_settings", Native.h3_config_set_additional_settings(config, settings), config)
  end

  @spec conn_new_with_transport(connection(), h3_config()) :: h3_connection()
  def conn_new_with_transport(conn, h3_config) do
    unwrap_ok!("h3_conn_new_with_transport", Native.h3_conn_new_with_transport(conn, h3_config))
  end

  @spec conn_poll(connection(), h3_connection()) :: {stream_id(), h3_event()} | :done
  def conn_poll(conn, h3_conn) do
    case Native.h3_conn_poll(conn, h3_conn) do
      {:ok, {stream_id, {:h3_headers, headers, more}}} ->
        {stream_id, {:headers, headers, more}}

      {:ok, {stream_id, event}} ->
        {stream_id, event}

      {:error, "done"} -> :done
      {:error, reason} -> raise Quichex.Native.ConfigError, message: reason, reason: reason
    end
  end

  @spec send_request(connection(), h3_connection(), [header()], boolean()) :: stream_id()
  def send_request(conn, h3_conn, headers, fin) do
    unwrap_ok!("h3_send_request", Native.h3_send_request(conn, h3_conn, headers, fin))
  end

  @spec send_response(connection(), h3_connection(), stream_id(), [header()], boolean()) :: :ok
  def send_response(conn, h3_conn, stream_id, headers, fin) do
    unwrap_ok!("h3_send_response", Native.h3_send_response(conn, h3_conn, stream_id, headers, fin))
    :ok
  end

  @spec send_body(connection(), h3_connection(), stream_id(), binary(), boolean()) :: :ok
  def send_body(conn, h3_conn, stream_id, body, fin) do
    unwrap_ok!("h3_send_body", Native.h3_send_body(conn, h3_conn, stream_id, body, fin))
    :ok
  end

  @spec recv_body(connection(), h3_connection(), stream_id(), non_neg_integer()) ::
          binary() | :done
  def recv_body(conn, h3_conn, stream_id, max_bytes) do
    case Native.h3_recv_body(conn, h3_conn, stream_id, max_bytes) do
      {:ok, data} -> data
      {:error, "done"} -> :done
      {:error, reason} -> raise Quichex.Native.ConfigError, message: reason, reason: reason
    end
  end

  @spec send_goaway(connection(), h3_connection(), stream_id()) :: :ok
  def send_goaway(conn, h3_conn, stream_id) do
    unwrap_ok!("h3_send_goaway", Native.h3_send_goaway(conn, h3_conn, stream_id))
    :ok
  end

  @spec extended_connect_enabled_by_peer(h3_connection()) :: boolean()
  def extended_connect_enabled_by_peer(h3_conn) do
    unwrap_ok!("h3_extended_connect_enabled_by_peer", Native.h3_extended_connect_enabled_by_peer(h3_conn))
  end

  @spec dgram_enabled_by_peer(connection(), h3_connection()) :: boolean()
  def dgram_enabled_by_peer(conn, h3_conn) do
    unwrap_ok!("h3_dgram_enabled_by_peer", Native.h3_dgram_enabled_by_peer(conn, h3_conn))
  end

  @doc """
  Send an HTTP/3 datagram with the given `flow_id`.

  For WebTransport, the datagram `flow_id` is the CONNECT stream id.
  """
  @spec send_datagram(connection(), non_neg_integer(), binary()) :: :ok
  def send_datagram(conn, flow_id, payload) when is_integer(flow_id) and flow_id >= 0 do
    encoded = IO.iodata_to_binary([encode_varint(flow_id), payload])
    unwrap_ok!("connection_dgram_send", Native.connection_dgram_send(conn, encoded))
    :ok
  end

  @doc """
  Receive an HTTP/3 datagram and decode its `flow_id`.

  Returns `{:ok, flow_id, payload}` or `:done` when no datagram is available.
  """
  @spec recv_datagram(connection(), non_neg_integer()) ::
          {:ok, non_neg_integer(), binary()} | :done
  def recv_datagram(conn, max_len) when is_integer(max_len) and max_len > 0 do
    case Native.connection_dgram_recv(conn, max_len) do
      {:ok, data} ->
        case decode_varint(data) do
          {:ok, flow_id, rest} -> {:ok, flow_id, rest}
          {:error, reason} -> raise Quichex.Native.ConfigError, message: reason, reason: reason
        end

      {:error, "done"} ->
        :done

      {:error, reason} ->
        raise Quichex.Native.ConfigError, message: reason, reason: reason
    end
  end

  defp unwrap_ok!(function, result, fallback \\ nil) do
    case result do
      :ok -> fallback
      {:ok, value} -> value
      {:error, reason} ->
        raise Quichex.Native.ConfigError,
          message: "#{function} failed: #{reason}",
          reason: reason,
          function: function

      other ->
        raise Quichex.Native.ConfigError,
          message: "#{function} failed: #{inspect(other)}",
          reason: inspect(other),
          function: function
    end
  end

  defp encode_varint(value) when value < 0x40 do
    <<0b00::2, value::6>>
  end

  defp encode_varint(value) when value < 0x4000 do
    <<0b01::2, value::14>>
  end

  defp encode_varint(value) when value < 0x4000_0000 do
    <<0b10::2, value::30>>
  end

  defp encode_varint(value) when value < 0x4000_0000_0000_0000 do
    <<0b11::2, value::62>>
  end

  defp encode_varint(value) do
    raise Quichex.Native.ConfigError,
      message: "flow_id out of range: #{value}",
      reason: "flow_id out of range"
  end

  defp decode_varint(<<>>), do: {:error, "empty datagram"}

  defp decode_varint(<<first, rest::binary>>) do
    length = first >>> 6
    case length do
      0 -> {:ok, first &&& 0x3F, rest}
      1 -> decode_varint_n(first, rest, 2)
      2 -> decode_varint_n(first, rest, 4)
      3 -> decode_varint_n(first, rest, 8)
    end
  end

  defp decode_varint_n(_first, rest, len) when byte_size(rest) + 1 < len do
    {:error, "incomplete varint"}
  end

  defp decode_varint_n(first, rest, 2) do
    <<b1, tail::binary>> = rest
    value = ((first &&& 0x3F) <<< 8) ||| b1
    {:ok, value, tail}
  end

  defp decode_varint_n(first, rest, 4) do
    <<b1, b2, b3, tail::binary>> = rest
    value = ((first &&& 0x3F) <<< 24) ||| (b1 <<< 16) ||| (b2 <<< 8) ||| b3
    {:ok, value, tail}
  end

  defp decode_varint_n(first, rest, 8) do
    <<b1, b2, b3, b4, b5, b6, b7, tail::binary>> = rest
    value =
      ((first &&& 0x3F) <<< 56) ||| (b1 <<< 48) ||| (b2 <<< 40) ||| (b3 <<< 32) |||
        (b4 <<< 24) ||| (b5 <<< 16) ||| (b6 <<< 8) ||| b7

    {:ok, value, tail}
  end
end
