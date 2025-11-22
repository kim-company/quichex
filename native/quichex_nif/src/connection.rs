use crate::resources::{ConfigResource, ConnectionResource};
use crate::types::{quiche_error_to_string, RecvInfo, SendInfo};
use rustler::{Binary, ResourceArc};
use std::sync::{Arc, Mutex};

const MAX_SEND_UDP_PAYLOAD_SIZE: usize = 1350;

/// Creates a new QUIC client connection
#[rustler::nif]
pub fn connection_new_client(
    scid: Binary,  // Connection ID as binary
    server_name: Option<String>,
    local_addr: Binary,  // 6 bytes for IPv4 (4 IP + 2 port) or 18 bytes for IPv6 (16 IP + 2 port)
    peer_addr: Binary,
    config: ResourceArc<ConfigResource>,
) -> Result<ResourceArc<ConnectionResource>, String> {
    let cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let scid_ref = quiche::ConnectionId::from_ref(scid.as_slice());

    // Parse addresses from binary
    let local_sock_addr = parse_address_binary(local_addr.as_slice())?;
    let peer_sock_addr = parse_address_binary(peer_addr.as_slice())?;

    // Clone the config for this connection
    let mut config_clone = {
        let _config_ref = &*cfg;
        drop(cfg); // Release the lock
        config.inner.lock().map_err(|e| format!("Lock error: {}", e))?
    };

    let conn = quiche::connect(
        server_name.as_deref(),
        &scid_ref,
        local_sock_addr,
        peer_sock_addr,
        &mut *config_clone,
    )
    .map_err(|e| format!("Failed to create connection: {:?}", e))?;

    Ok(ResourceArc::new(ConnectionResource {
        inner: Arc::new(Mutex::new(conn)),
    }))
}

fn parse_address_binary(addr: &[u8]) -> Result<std::net::SocketAddr, String> {
    if addr.len() == 6 {
        // IPv4: 4 bytes IP + 2 bytes port (big endian)
        let ip = std::net::Ipv4Addr::new(addr[0], addr[1], addr[2], addr[3]);
        let port = u16::from_be_bytes([addr[4], addr[5]]);
        Ok(std::net::SocketAddr::from((ip, port)))
    } else if addr.len() == 18 {
        // IPv6: 16 bytes IP + 2 bytes port (big endian)
        let segments = [
            u16::from_be_bytes([addr[0], addr[1]]),
            u16::from_be_bytes([addr[2], addr[3]]),
            u16::from_be_bytes([addr[4], addr[5]]),
            u16::from_be_bytes([addr[6], addr[7]]),
            u16::from_be_bytes([addr[8], addr[9]]),
            u16::from_be_bytes([addr[10], addr[11]]),
            u16::from_be_bytes([addr[12], addr[13]]),
            u16::from_be_bytes([addr[14], addr[15]]),
        ];
        let ip = std::net::Ipv6Addr::new(
            segments[0], segments[1], segments[2], segments[3],
            segments[4], segments[5], segments[6], segments[7],
        );
        let port = u16::from_be_bytes([addr[16], addr[17]]);
        Ok(std::net::SocketAddr::from((ip, port)))
    } else {
        Err(format!(
            "Invalid address binary length: expected 6 (IPv4) or 18 (IPv6) bytes, got {}",
            addr.len()
        ))
    }
}

/// Processes a received QUIC packet
#[rustler::nif]
pub fn connection_recv(
    conn: ResourceArc<ConnectionResource>,
    packet: Binary,
    recv_info: RecvInfo,
) -> Result<usize, String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let info = recv_info.into_quiche();

    // Need to copy packet data to mutable buffer for quiche
    let mut buf = packet.as_slice().to_vec();

    connection
        .recv(&mut buf, info)
        .map_err(|e| match e {
            quiche::Error::Done => "done".to_string(),
            _ => format!("Recv error: {}", quiche_error_to_string(e)),
        })
}

/// Generates a QUIC packet to send
#[rustler::nif]
pub fn connection_send(
    conn: ResourceArc<ConnectionResource>,
) -> Result<(Vec<u8>, SendInfo), String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let mut out = vec![0u8; MAX_SEND_UDP_PAYLOAD_SIZE];

    match connection.send(&mut out) {
        Ok((written, send_info)) => {
            // Return only the written portion
            out.truncate(written);
            Ok((out, SendInfo::from_quiche(send_info)))
        }
        Err(quiche::Error::Done) => Err("done".to_string()),
        Err(e) => Err(format!("Send error: {}", quiche_error_to_string(e))),
    }
}

/// Gets the connection timeout (for timer scheduling)
#[rustler::nif]
pub fn connection_timeout(conn: ResourceArc<ConnectionResource>) -> Result<Option<u64>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.timeout().map(|d| d.as_millis() as u64))
}

/// Handles timeout event on the connection
#[rustler::nif]
pub fn connection_on_timeout(conn: ResourceArc<ConnectionResource>) -> Result<(), String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    connection.on_timeout();
    Ok(())
}

/// Checks if the connection handshake is complete
#[rustler::nif]
pub fn connection_is_established(conn: ResourceArc<ConnectionResource>) -> Result<bool, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.is_established())
}

/// Checks if the connection is closed
#[rustler::nif]
pub fn connection_is_closed(conn: ResourceArc<ConnectionResource>) -> Result<bool, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.is_closed())
}

/// Checks if the connection is in the draining state
#[rustler::nif]
pub fn connection_is_draining(conn: ResourceArc<ConnectionResource>) -> Result<bool, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.is_draining())
}

/// Closes the connection with an error code and reason
#[rustler::nif]
pub fn connection_close(
    conn: ResourceArc<ConnectionResource>,
    app: bool,
    err: u64,
    reason: Vec<u8>,
) -> Result<(), String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    connection
        .close(app, err, &reason)
        .map_err(|e| format!("Close error: {}", quiche_error_to_string(e)))
}

/// Gets the connection trace ID for logging
#[rustler::nif]
pub fn connection_trace_id(conn: ResourceArc<ConnectionResource>) -> Result<String, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.trace_id().to_string())
}

/// Gets the source connection ID
#[rustler::nif]
pub fn connection_source_id(conn: ResourceArc<ConnectionResource>) -> Result<Vec<u8>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.source_id().into_owned().to_vec())
}

/// Gets the destination connection ID
#[rustler::nif]
pub fn connection_destination_id(
    conn: ResourceArc<ConnectionResource>,
) -> Result<Vec<u8>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.destination_id().into_owned().to_vec())
}

/// Gets the negotiated application protocol (ALPN)
#[rustler::nif]
pub fn connection_application_proto(
    conn: ResourceArc<ConnectionResource>,
) -> Result<Vec<u8>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.application_proto().to_vec())
}

/// Gets the peer's certificate chain (DER encoded)
#[rustler::nif]
pub fn connection_peer_cert(
    conn: ResourceArc<ConnectionResource>,
) -> Result<Option<Vec<Vec<u8>>>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    // quiche returns Vec<u8> for peer_cert, just wrap in Option<Vec<Vec<u8>>>
    Ok(connection.peer_cert().map(|cert| vec![cert.to_vec()]))
}

/// Checks if the connection is in early data (0-RTT) state
#[rustler::nif]
pub fn connection_is_in_early_data(conn: ResourceArc<ConnectionResource>) -> Result<bool, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.is_in_early_data())
}
