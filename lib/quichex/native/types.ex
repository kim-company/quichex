defmodule Quichex.Native.PacketHeader do
  @moduledoc false
  defstruct [:ty, :version, :dcid, :scid, :token]
end

defmodule Quichex.Native.ConnectionError do
  @moduledoc false
  defstruct [:is_app, :error_code, :reason]
end

defmodule Quichex.Native.ConnectionStats do
  @moduledoc false
  defstruct [
    :recv,
    :sent,
    :lost,
    :retrans,
    :sent_bytes,
    :recv_bytes,
    :lost_bytes,
    :stream_retrans_bytes,
    :paths_count,
    :delivery_rate,
    :rtt,
    :min_rtt,
    :rttvar
  ]
end

defmodule Quichex.Native.TransportParams do
  @moduledoc false
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
end
