defmodule Quichex.Native.PacketHeader do
  @moduledoc """
  Representation of the parsed QUIC packet header returned by `Native.header_info/2`.
  """
  @enforce_keys [:ty, :version, :dcid, :scid]
  defstruct [:ty, :version, :dcid, :scid, :token]

  @type t :: %__MODULE__{
          ty: non_neg_integer(),
          version: non_neg_integer(),
          dcid: binary(),
          scid: binary(),
          token: binary() | nil
        }
end

defmodule Quichex.Native.ConnectionError do
  @moduledoc """
  Wrapper for `quiche::ConnectionError`. Returned by `connection_peer_error/1`
  and `connection_local_error/1` for human-friendly inspection.
  """
  @enforce_keys [:is_app, :error_code]
  defstruct [:is_app, :error_code, :reason]

  @type t :: %__MODULE__{
          is_app: boolean(),
          error_code: non_neg_integer(),
          reason: binary() | nil
        }
end

defmodule Quichex.Native.ConnectionStats do
  @moduledoc """
  Snapshot of `quiche::Stats`, exposed via `Native.connection_stats/1`.
  """
  @enforce_keys [
    :recv,
    :sent,
    :lost,
    :spurious_lost,
    :retrans,
    :sent_bytes,
    :recv_bytes,
    :acked_bytes,
    :lost_bytes,
    :stream_retrans_bytes,
    :dgram_recv,
    :dgram_sent,
    :paths_count,
    :reset_stream_count_local,
    :stopped_stream_count_local,
    :reset_stream_count_remote,
    :stopped_stream_count_remote,
    :path_challenge_rx_count,
    :bytes_in_flight_duration_us
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          recv: non_neg_integer(),
          sent: non_neg_integer(),
          lost: non_neg_integer(),
          spurious_lost: non_neg_integer(),
          retrans: non_neg_integer(),
          sent_bytes: non_neg_integer(),
          recv_bytes: non_neg_integer(),
          acked_bytes: non_neg_integer(),
          lost_bytes: non_neg_integer(),
          stream_retrans_bytes: non_neg_integer(),
          dgram_recv: non_neg_integer(),
          dgram_sent: non_neg_integer(),
          paths_count: non_neg_integer(),
          reset_stream_count_local: non_neg_integer(),
          stopped_stream_count_local: non_neg_integer(),
          reset_stream_count_remote: non_neg_integer(),
          stopped_stream_count_remote: non_neg_integer(),
          path_challenge_rx_count: non_neg_integer(),
          bytes_in_flight_duration_us: non_neg_integer()
        }
end

defmodule Quichex.Native.TransportParams do
  @moduledoc """
  Negotiated QUIC transport parameters provided by the peer.
  """
  @enforce_keys [
    :max_idle_timeout,
    :max_udp_payload_size,
    :initial_max_data,
    :initial_max_stream_data_bidi_local,
    :initial_max_stream_data_bidi_remote,
    :initial_max_stream_data_uni,
    :initial_max_streams_bidi,
    :initial_max_streams_uni,
    :ack_delay_exponent,
    :max_ack_delay,
    :disable_active_migration,
    :active_conn_id_limit
  ]
  defstruct [
    :max_idle_timeout,
    :max_udp_payload_size,
    :initial_max_data,
    :initial_max_stream_data_bidi_local,
    :initial_max_stream_data_bidi_remote,
    :initial_max_stream_data_uni,
    :initial_max_streams_bidi,
    :initial_max_streams_uni,
    :ack_delay_exponent,
    :max_ack_delay,
    :disable_active_migration,
    :active_conn_id_limit,
    :max_datagram_frame_size
  ]

  @type t :: %__MODULE__{
          max_idle_timeout: non_neg_integer(),
          max_udp_payload_size: non_neg_integer(),
          initial_max_data: non_neg_integer(),
          initial_max_stream_data_bidi_local: non_neg_integer(),
          initial_max_stream_data_bidi_remote: non_neg_integer(),
          initial_max_stream_data_uni: non_neg_integer(),
          initial_max_streams_bidi: non_neg_integer(),
          initial_max_streams_uni: non_neg_integer(),
          ack_delay_exponent: non_neg_integer(),
          max_ack_delay: non_neg_integer(),
          disable_active_migration: boolean(),
          active_conn_id_limit: non_neg_integer(),
          max_datagram_frame_size: non_neg_integer() | nil
        }
end
