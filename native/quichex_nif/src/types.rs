use rustler::{Decoder, Encoder, Env, NifResult, NifStruct, Term};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

// Define atoms for map keys
rustler::atoms! {
    from,
    to,
    at_micros,
}

/// Represents socket address information passed between Elixir and Rust
/// Elixir format: {{ip1, ip2, ip3, ip4}, port} for IPv4
///                {{ip1, ip2, ip3, ip4, ip5, ip6, ip7, ip8}, port} for IPv6
#[derive(Debug, Clone)]
pub struct SocketAddress(pub SocketAddr);

impl Encoder for SocketAddress {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self.0 {
            SocketAddr::V4(addr) => {
                let octets = addr.ip().octets();
                let ip_tuple = (octets[0], octets[1], octets[2], octets[3]);
                (ip_tuple, addr.port()).encode(env)
            }
            SocketAddr::V6(addr) => {
                let segments = addr.ip().segments();
                // IPv6 encoded as list of 8 u16 values
                let ip_list: Vec<u16> = segments.to_vec();
                (ip_list, addr.port()).encode(env)
            }
        }
    }
}

impl<'a> Decoder<'a> for SocketAddress {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        let (ip_term, port): (Term, u16) = term.decode()?;

        // Try to decode as IPv4 first
        if let Ok((a, b, c, d)) = ip_term.decode::<(u8, u8, u8, u8)>() {
            let ip = IpAddr::V4(Ipv4Addr::new(a, b, c, d));
            return Ok(SocketAddress(SocketAddr::new(ip, port)));
        }

        // Try to decode as IPv6 (as list of 8 u16 values)
        if let Ok(segments) = ip_term.decode::<Vec<u16>>() {
            if segments.len() == 8 {
                let ip = IpAddr::V6(Ipv6Addr::new(
                    segments[0],
                    segments[1],
                    segments[2],
                    segments[3],
                    segments[4],
                    segments[5],
                    segments[6],
                    segments[7],
                ));
                return Ok(SocketAddress(SocketAddr::new(ip, port)));
            }
        }

        Err(rustler::Error::BadArg)
    }
}

/// Represents quiche::RecvInfo for packet reception
/// Maps to Elixir map: %{from: {{ip}, port}, to: {{ip}, port}}
#[derive(Debug, Clone)]
pub struct RecvInfo {
    pub from: SocketAddr,
    pub to: SocketAddr,
}

impl RecvInfo {
    pub fn into_quiche(self) -> quiche::RecvInfo {
        quiche::RecvInfo {
            from: self.from,
            to: self.to,
        }
    }
}

impl<'a> Decoder<'a> for RecvInfo {
    fn decode(term: Term<'a>) -> NifResult<Self> {
        let from: SocketAddress = term.map_get(from().encode(term.get_env()))?.decode()?;
        let to: SocketAddress = term.map_get(to().encode(term.get_env()))?.decode()?;

        Ok(RecvInfo {
            from: from.0,
            to: to.0,
        })
    }
}

/// Represents quiche::SendInfo for packet transmission
/// Maps to Elixir map: %{from: {{ip}, port}, to: {{ip}, port}, at: Time.t()}
#[derive(Debug, Clone)]
pub struct SendInfo {
    pub from: SocketAddr,
    pub to: SocketAddr,
    pub at: std::time::Instant,
}

impl SendInfo {
    pub fn from_quiche(info: quiche::SendInfo) -> Self {
        SendInfo {
            from: info.from,
            to: info.to,
            at: info.at,
        }
    }
}

impl Encoder for SendInfo {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        use rustler::types::map::map_new;

        let map = map_new(env);
        let map = map
            .map_put(from().encode(env), SocketAddress(self.from).encode(env))
            .ok()
            .unwrap();
        let map = map
            .map_put(to().encode(env), SocketAddress(self.to).encode(env))
            .ok()
            .unwrap();

        // Convert Instant to elapsed microseconds since epoch for Elixir
        // Note: Elixir will need to interpret this as needed
        let elapsed_micros = self.at.elapsed().as_micros().min(i64::MAX as u128) as i64;
        map.map_put(at_micros().encode(env), elapsed_micros.encode(env))
            .ok()
            .unwrap()
    }
}

#[derive(NifStruct, Debug, Clone)]
#[module = "Quichex.Native.ConnectionError"]
pub struct ConnectionErrorInfo {
    pub is_app: bool,
    pub error_code: u64,
    pub reason: Option<Vec<u8>>,
}

impl ConnectionErrorInfo {
    pub fn from_quiche(err: &quiche::ConnectionError) -> Self {
        ConnectionErrorInfo {
            is_app: err.is_app,
            error_code: err.error_code,
            reason: if err.reason.is_empty() {
                None
            } else {
                Some(err.reason.clone())
            },
        }
    }
}

#[derive(NifStruct, Debug, Clone)]
#[module = "Quichex.Native.ConnectionStats"]
pub struct ConnectionStats {
    pub recv: usize,
    pub sent: usize,
    pub lost: usize,
    pub spurious_lost: usize,
    pub retrans: usize,
    pub sent_bytes: u64,
    pub recv_bytes: u64,
    pub acked_bytes: u64,
    pub lost_bytes: u64,
    pub stream_retrans_bytes: u64,
    pub dgram_recv: usize,
    pub dgram_sent: usize,
    pub paths_count: usize,
    pub reset_stream_count_local: u64,
    pub stopped_stream_count_local: u64,
    pub reset_stream_count_remote: u64,
    pub stopped_stream_count_remote: u64,
    pub path_challenge_rx_count: u64,
    pub bytes_in_flight_duration_us: u64,
}

impl From<quiche::Stats> for ConnectionStats {
    fn from(stats: quiche::Stats) -> Self {
        ConnectionStats {
            recv: stats.recv,
            sent: stats.sent,
            lost: stats.lost,
            spurious_lost: stats.spurious_lost,
            retrans: stats.retrans,
            sent_bytes: stats.sent_bytes,
            recv_bytes: stats.recv_bytes,
            acked_bytes: stats.acked_bytes,
            lost_bytes: stats.lost_bytes,
            stream_retrans_bytes: stats.stream_retrans_bytes,
            dgram_recv: stats.dgram_recv,
            dgram_sent: stats.dgram_sent,
            paths_count: stats.paths_count,
            reset_stream_count_local: stats.reset_stream_count_local,
            stopped_stream_count_local: stats.stopped_stream_count_local,
            reset_stream_count_remote: stats.reset_stream_count_remote,
            stopped_stream_count_remote: stats.stopped_stream_count_remote,
            path_challenge_rx_count: stats.path_challenge_rx_count,
            bytes_in_flight_duration_us: stats
                .bytes_in_flight_duration
                .as_micros()
                .min(u64::MAX as u128) as u64,
        }
    }
}

#[derive(NifStruct, Debug, Clone)]
#[module = "Quichex.Native.TransportParams"]
pub struct TransportParams {
    pub max_idle_timeout: u64,
    pub max_udp_payload_size: u64,
    pub initial_max_data: u64,
    pub initial_max_stream_data_bidi_local: u64,
    pub initial_max_stream_data_bidi_remote: u64,
    pub initial_max_stream_data_uni: u64,
    pub initial_max_streams_bidi: u64,
    pub initial_max_streams_uni: u64,
    pub ack_delay_exponent: u64,
    pub max_ack_delay: u64,
    pub disable_active_migration: bool,
    pub active_conn_id_limit: u64,
    pub max_datagram_frame_size: Option<u64>,
}

impl From<quiche::TransportParams> for TransportParams {
    fn from(params: quiche::TransportParams) -> Self {
        TransportParams {
            max_idle_timeout: params.max_idle_timeout,
            max_udp_payload_size: params.max_udp_payload_size,
            initial_max_data: params.initial_max_data,
            initial_max_stream_data_bidi_local: params.initial_max_stream_data_bidi_local,
            initial_max_stream_data_bidi_remote: params.initial_max_stream_data_bidi_remote,
            initial_max_stream_data_uni: params.initial_max_stream_data_uni,
            initial_max_streams_bidi: params.initial_max_streams_bidi,
            initial_max_streams_uni: params.initial_max_streams_uni,
            ack_delay_exponent: params.ack_delay_exponent,
            max_ack_delay: params.max_ack_delay,
            disable_active_migration: params.disable_active_migration,
            active_conn_id_limit: params.active_conn_id_limit,
            max_datagram_frame_size: params.max_datagram_frame_size.map(|v| v as u64),
        }
    }
}

/// Maps quiche errors to Elixir-friendly error atoms/strings
pub fn quiche_error_to_string(err: quiche::Error) -> String {
    match err {
        quiche::Error::Done => "done".to_string(),
        quiche::Error::BufferTooShort => "buffer_too_short".to_string(),
        quiche::Error::UnknownVersion => "unknown_version".to_string(),
        quiche::Error::InvalidFrame => "invalid_frame".to_string(),
        quiche::Error::InvalidPacket => "invalid_packet".to_string(),
        quiche::Error::InvalidState => "invalid_state".to_string(),
        quiche::Error::InvalidStreamState(_) => "invalid_stream_state".to_string(),
        quiche::Error::InvalidTransportParam => "invalid_transport_param".to_string(),
        quiche::Error::FlowControl => "flow_control".to_string(),
        quiche::Error::StreamLimit => "stream_limit".to_string(),
        quiche::Error::StreamStopped(_) => "stream_stopped".to_string(),
        quiche::Error::StreamReset(_) => "stream_reset".to_string(),
        quiche::Error::FinalSize => "final_size".to_string(),
        quiche::Error::CongestionControl => "congestion_control".to_string(),
        quiche::Error::IdLimit => "id_limit".to_string(),
        quiche::Error::OutOfIdentifiers => "out_of_identifiers".to_string(),
        quiche::Error::KeyUpdate => "key_update".to_string(),
        quiche::Error::CryptoFail => "crypto_fail".to_string(),
        quiche::Error::TlsFail => "tls_fail".to_string(),
        quiche::Error::CryptoBufferExceeded => "crypto_buffer_exceeded".to_string(),
        quiche::Error::InvalidAckRange => "invalid_ack_range".to_string(),
        quiche::Error::OptimisticAckDetected => "optimistic_ack_detected".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ipv4_socket_address() {
        let addr = SocketAddr::new(IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)), 8080);
        let socket_addr = SocketAddress(addr);
        assert_eq!(socket_addr.0.ip(), IpAddr::V4(Ipv4Addr::new(127, 0, 0, 1)));
        assert_eq!(socket_addr.0.port(), 8080);
    }

    #[test]
    fn test_ipv6_socket_address() {
        let addr = SocketAddr::new(IpAddr::V6(Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 1)), 8080);
        let socket_addr = SocketAddress(addr);
        assert_eq!(
            socket_addr.0.ip(),
            IpAddr::V6(Ipv6Addr::new(0, 0, 0, 0, 0, 0, 0, 1))
        );
        assert_eq!(socket_addr.0.port(), 8080);
    }

    #[test]
    fn test_quiche_error_mapping() {
        assert_eq!(quiche_error_to_string(quiche::Error::Done), "done");
        assert_eq!(
            quiche_error_to_string(quiche::Error::BufferTooShort),
            "buffer_too_short"
        );
        assert_eq!(
            quiche_error_to_string(quiche::Error::FlowControl),
            "flow_control"
        );
    }
}
