use crate::resources::{ConfigResource, ConnectionResource};
use crate::types::{
    quiche_error_to_string, ConnectionErrorInfo, ConnectionStats, RecvInfo, SendInfo,
    TransportParams,
};
use rustler::{Binary, OwnedBinary, ResourceArc};
use std::collections::HashSet;
use std::fs::OpenOptions;
use std::io::BufWriter;
use std::sync::{Arc, Mutex};

const MAX_SEND_UDP_PAYLOAD_SIZE: usize = 1350;

/// Creates a new QUIC client connection
#[rustler::nif]
pub fn connection_new_client(
    scid: Binary, // Connection ID as binary
    server_name: Option<String>,
    local_addr: Binary, // 6 bytes for IPv4 (4 IP + 2 port) or 18 bytes for IPv6 (16 IP + 2 port)
    peer_addr: Binary,
    config: ResourceArc<ConfigResource>,
    stream_recv_buffer_size: usize, // Buffer size for stream reads
) -> Result<ResourceArc<ConnectionResource>, String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let scid_ref = quiche::ConnectionId::from_ref(scid.as_slice());

    // Parse addresses from binary
    let local_sock_addr = parse_address_binary(local_addr.as_slice())?;
    let peer_sock_addr = parse_address_binary(peer_addr.as_slice())?;

    let conn = quiche::connect(
        server_name.as_deref(),
        &scid_ref,
        local_sock_addr,
        peer_sock_addr,
        &mut *cfg,
    )
    .map_err(|e| format!("Failed to create connection: {:?}", e))?;

    let _ = stream_recv_buffer_size; // parameter kept for API compatibility

    Ok(ResourceArc::new(ConnectionResource {
        inner: Arc::new(Mutex::new(conn)),
        known_streams: Arc::new(Mutex::new(HashSet::new())),
    }))
}

/// Creates a new QUIC server connection
#[rustler::nif]
pub fn connection_new_server(
    scid: Binary,          // Server's connection ID
    odcid: Option<Binary>, // Original destination connection ID (for retry packets)
    local_addr: Binary,    // 6 bytes for IPv4 or 18 bytes for IPv6
    peer_addr: Binary,
    config: ResourceArc<ConfigResource>,
    stream_recv_buffer_size: usize,
) -> Result<ResourceArc<ConnectionResource>, String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let scid_ref = quiche::ConnectionId::from_ref(scid.as_slice());

    // Parse optional original destination connection ID
    let odcid_ref = odcid
        .as_ref()
        .map(|b| quiche::ConnectionId::from_ref(b.as_slice()));

    // Parse addresses from binary
    let local_sock_addr = parse_address_binary(local_addr.as_slice())?;
    let peer_sock_addr = parse_address_binary(peer_addr.as_slice())?;

    // KEY DIFFERENCE: Use quiche::accept() for server instead of quiche::connect()
    let conn = quiche::accept(
        &scid_ref,
        odcid_ref.as_ref(),
        local_sock_addr,
        peer_sock_addr,
        &mut *cfg,
    )
    .map_err(|e| format!("Failed to accept connection: {:?}", e))?;

    let _ = stream_recv_buffer_size;

    Ok(ResourceArc::new(ConnectionResource {
        inner: Arc::new(Mutex::new(conn)),
        known_streams: Arc::new(Mutex::new(HashSet::new())),
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
            segments[0],
            segments[1],
            segments[2],
            segments[3],
            segments[4],
            segments[5],
            segments[6],
            segments[7],
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

    // TODO: quiche::Connection::recv() requires &mut [u8], but likely doesn't actually
    // mutate the buffer (it only reads the incoming packet). We could potentially avoid
    // this copy with unsafe casting, but keeping it safe for now.
    let mut buf = packet.as_slice().to_vec();

    connection.recv(&mut buf, info).map_err(|e| match e {
        quiche::Error::Done => "done".to_string(),
        _ => format!("Recv error: {}", quiche_error_to_string(e)),
    })
}

/// Generates a QUIC packet to send
#[rustler::nif]
pub fn connection_send<'a>(
    env: rustler::Env<'a>,
    conn: ResourceArc<ConnectionResource>,
) -> Result<(rustler::Binary<'a>, SendInfo), String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let mut binary = OwnedBinary::new(MAX_SEND_UDP_PAYLOAD_SIZE)
        .ok_or_else(|| "Failed to allocate binary".to_string())?;
    let out = binary.as_mut_slice();

    match connection.send(out) {
        Ok((written, send_info)) => {
            if written < MAX_SEND_UDP_PAYLOAD_SIZE && !binary.realloc(written) {
                return Err("Failed to shrink binary".to_string());
            }

            Ok((binary.release(env), SendInfo::from_quiche(send_info)))
        }
        Err(quiche::Error::Done) => Err("done".to_string()),
        Err(e) => Err(format!("Send error: {}", quiche_error_to_string(e))),
    }
}

/// Gets the connection timeout (for timer scheduling)
#[rustler::nif]
pub fn connection_timeout(conn: ResourceArc<ConnectionResource>) -> Result<u64, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let timeout = connection
        .timeout()
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);

    Ok(timeout)
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

/// Checks if the connection resumed from session resumption
#[rustler::nif]
pub fn connection_is_resumed(conn: ResourceArc<ConnectionResource>) -> Result<bool, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.is_resumed())
}

/// Checks if the connection timed out
#[rustler::nif]
pub fn connection_is_timed_out(conn: ResourceArc<ConnectionResource>) -> Result<bool, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.is_timed_out())
}

/// Returns true if this side is the QUIC server
#[rustler::nif]
pub fn connection_is_server(conn: ResourceArc<ConnectionResource>) -> Result<bool, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.is_server())
}

/// Closes the connection with an error code and reason
#[rustler::nif]
pub fn connection_close(
    conn: ResourceArc<ConnectionResource>,
    app: bool,
    err: u64,
    reason: Binary,
) -> Result<(), String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    connection
        .close(app, err, reason.as_slice())
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
pub fn connection_source_id<'a>(
    env: rustler::Env<'a>,
    conn: ResourceArc<ConnectionResource>,
) -> Result<rustler::Binary<'a>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let id = connection.source_id().into_owned();
    let mut binary =
        OwnedBinary::new(id.len()).ok_or_else(|| "Failed to allocate binary".to_string())?;
    binary.as_mut_slice().copy_from_slice(&id);

    Ok(binary.release(env))
}

/// Gets the destination connection ID
#[rustler::nif]
pub fn connection_destination_id<'a>(
    env: rustler::Env<'a>,
    conn: ResourceArc<ConnectionResource>,
) -> Result<rustler::Binary<'a>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let id = connection.destination_id().into_owned();
    let mut binary =
        OwnedBinary::new(id.len()).ok_or_else(|| "Failed to allocate binary".to_string())?;
    binary.as_mut_slice().copy_from_slice(&id);

    Ok(binary.release(env))
}

/// Gets the negotiated application protocol (ALPN)
#[rustler::nif]
pub fn connection_application_proto<'a>(
    env: rustler::Env<'a>,
    conn: ResourceArc<ConnectionResource>,
) -> Result<rustler::Binary<'a>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let proto = connection.application_proto();
    let mut binary =
        OwnedBinary::new(proto.len()).ok_or_else(|| "Failed to allocate binary".to_string())?;
    binary.as_mut_slice().copy_from_slice(proto);

    Ok(binary.release(env))
}

/// Gets the peer's certificate chain (DER encoded)
#[rustler::nif]
pub fn connection_peer_cert<'a>(
    env: rustler::Env<'a>,
    conn: ResourceArc<ConnectionResource>,
) -> Result<Option<Vec<rustler::Binary<'a>>>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    match connection.peer_cert() {
        Some(cert) => {
            let mut binary = OwnedBinary::new(cert.len())
                .ok_or_else(|| "Failed to allocate binary".to_string())?;
            binary.as_mut_slice().copy_from_slice(cert);
            Ok(Some(vec![binary.release(env)]))
        }
        None => Ok(None),
    }
}

/// Returns peer-side error information if available
#[rustler::nif]
pub fn connection_peer_error(
    conn: ResourceArc<ConnectionResource>,
) -> Result<Option<ConnectionErrorInfo>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection
        .peer_error()
        .map(ConnectionErrorInfo::from_quiche))
}

/// Returns local error information if present
#[rustler::nif]
pub fn connection_local_error(
    conn: ResourceArc<ConnectionResource>,
) -> Result<Option<ConnectionErrorInfo>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection
        .local_error()
        .map(ConnectionErrorInfo::from_quiche))
}

/// Fetches aggregated connection statistics
#[rustler::nif]
pub fn connection_stats(conn: ResourceArc<ConnectionResource>) -> Result<ConnectionStats, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.stats().into())
}

/// Returns the peer transport parameters if available
#[rustler::nif]
pub fn connection_peer_transport_params(
    conn: ResourceArc<ConnectionResource>,
) -> Result<Option<TransportParams>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection
        .peer_transport_params()
        .map(|params| TransportParams::from(params.clone())))
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

/// Enables TLS key logging to the provided file path
#[rustler::nif]
pub fn connection_set_keylog_path(
    conn: ResourceArc<ConnectionResource>,
    path: String,
) -> Result<(), String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| format!("Failed to open keylog path {}: {}", path, e))?;
    let writer = BufWriter::new(file);
    connection.set_keylog(Box::new(writer));
    Ok(())
}

/// Sets TLS session data for resumption/0-RTT
#[rustler::nif]
pub fn connection_set_session(
    conn: ResourceArc<ConnectionResource>,
    data: Binary,
) -> Result<(), String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    connection
        .set_session(data.as_slice())
        .map_err(|e| format!("Failed to set session: {}", quiche_error_to_string(e)))
}

/// Returns peer-provided TLS session data if available
#[rustler::nif]
pub fn connection_session<'a>(
    env: rustler::Env<'a>,
    conn: ResourceArc<ConnectionResource>,
) -> Result<Option<rustler::Binary<'a>>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    if let Some(session) = connection.session() {
        let mut binary = OwnedBinary::new(session.len())
            .ok_or_else(|| "Failed to allocate binary".to_string())?;
        binary.as_mut_slice().copy_from_slice(session);
        Ok(Some(binary.release(env)))
    } else {
        Ok(None)
    }
}

/// Returns the peer's SNI if one was offered
#[rustler::nif]
pub fn connection_server_name(
    conn: ResourceArc<ConnectionResource>,
) -> Result<Option<String>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.server_name().map(|s| s.to_string()))
}

fn record_known_stream(
    conn: &ResourceArc<ConnectionResource>,
    stream_id: u64,
) -> Result<(), String> {
    let mut known_streams = conn
        .known_streams
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    known_streams.insert(stream_id);
    Ok(())
}

fn record_known_streams(
    conn: &ResourceArc<ConnectionResource>,
    stream_ids: &[u64],
) -> Result<(), String> {
    if stream_ids.is_empty() {
        return Ok(());
    }

    let mut known_streams = conn
        .known_streams
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    for stream_id in stream_ids {
        known_streams.insert(*stream_id);
    }

    Ok(())
}

fn stream_is_known(conn: &ResourceArc<ConnectionResource>, stream_id: u64) -> Result<bool, String> {
    let known_streams = conn
        .known_streams
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(known_streams.contains(&stream_id))
}

/// Sends data on a stream
#[rustler::nif]
pub fn connection_stream_send(
    conn: ResourceArc<ConnectionResource>,
    stream_id: u64,
    data: Binary,
    fin: bool,
) -> Result<usize, String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    match connection.stream_send(stream_id, data.as_slice(), fin) {
        Ok(bytes_written) => {
            record_known_stream(&conn, stream_id)?;
            Ok(bytes_written)
        }
        // Done means flow control exhausted - return 0 bytes written, not an error
        Err(quiche::Error::Done) => {
            record_known_stream(&conn, stream_id)?;
            Ok(0)
        }
        // All other errors are real errors
        Err(e) => Err(format!("Stream send error: {}", quiche_error_to_string(e))),
    }
}

/// Receives data from a stream
#[rustler::nif]
pub fn connection_stream_recv<'a>(
    env: rustler::Env<'a>,
    conn: ResourceArc<ConnectionResource>,
    stream_id: u64,
    max_len: usize,
) -> Result<(rustler::Binary<'a>, bool), String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let mut binary =
        OwnedBinary::new(max_len).ok_or_else(|| "Failed to allocate binary".to_string())?;
    let buf = binary.as_mut_slice();

    match connection.stream_recv(stream_id, buf) {
        Ok((read, fin)) => {
            if read < max_len && !binary.realloc(read) {
                return Err("Failed to shrink binary".to_string());
            }

            record_known_stream(&conn, stream_id)?;

            Ok((binary.release(env), fin))
        }
        Err(e) => Err(format!("Stream recv error: {}", quiche_error_to_string(e))),
    }
}

/// Gets list of streams that have data to read
#[rustler::nif]
pub fn connection_readable_streams(
    conn: ResourceArc<ConnectionResource>,
) -> Result<Vec<u64>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let streams: Vec<u64> = connection.readable().collect();
    record_known_streams(&conn, &streams)?;
    Ok(streams)
}

/// Gets list of streams that can be written to
#[rustler::nif]
pub fn connection_writable_streams(
    conn: ResourceArc<ConnectionResource>,
) -> Result<Vec<u64>, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let streams: Vec<u64> = connection.writable().collect();
    record_known_streams(&conn, &streams)?;
    Ok(streams)
}

/// Checks if a stream has finished reading
#[rustler::nif]
pub fn connection_stream_finished(
    conn: ResourceArc<ConnectionResource>,
    stream_id: u64,
) -> Result<bool, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let finished = connection.stream_finished(stream_id);
    drop(connection);

    if !finished {
        return Ok(false);
    }

    if stream_is_known(&conn, stream_id)? {
        Ok(true)
    } else {
        Ok(false)
    }
}

/// Shuts down stream in the specified direction
#[rustler::nif]
pub fn connection_stream_shutdown(
    conn: ResourceArc<ConnectionResource>,
    stream_id: u64,
    direction: String,
    err_code: u64,
) -> Result<(), String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let shutdown = match direction.as_str() {
        "read" => quiche::Shutdown::Read,
        "write" => quiche::Shutdown::Write,
        "both" => {
            // Shutdown both directions - ignore Done errors
            let _ = connection.stream_shutdown(stream_id, quiche::Shutdown::Read, err_code);
            let _ = connection.stream_shutdown(stream_id, quiche::Shutdown::Write, err_code);
            return Ok(());
        }
        _ => return Err(format!("Invalid direction: {}", direction)),
    };

    connection
        .stream_shutdown(stream_id, shutdown, err_code)
        .or_else(|e| match e {
            quiche::Error::Done => Ok(()), // Treat Done as success
            _ => Err(format!(
                "Stream shutdown error: {}",
                quiche_error_to_string(e)
            )),
        })
}

/// Returns maximum writable datagram payload length
#[rustler::nif]
pub fn connection_dgram_max_writable_len(
    conn: ResourceArc<ConnectionResource>,
) -> Result<usize, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    if let Some(len) = connection.dgram_max_writable_len() {
        return Ok(len);
    }

    // Fall back to the current UDP payload size so we at least expose the local
    // limit before the peer advertises DATAGRAM support.
    Ok(connection.max_send_udp_payload_size())
}

#[rustler::nif]
pub fn connection_dgram_recv_queue_len(
    conn: ResourceArc<ConnectionResource>,
) -> Result<usize, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.dgram_recv_queue_len())
}

#[rustler::nif]
pub fn connection_dgram_recv_queue_byte_size(
    conn: ResourceArc<ConnectionResource>,
) -> Result<usize, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.dgram_recv_queue_byte_size())
}

#[rustler::nif]
pub fn connection_dgram_send_queue_len(
    conn: ResourceArc<ConnectionResource>,
) -> Result<usize, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.dgram_send_queue_len())
}

#[rustler::nif]
pub fn connection_dgram_send_queue_byte_size(
    conn: ResourceArc<ConnectionResource>,
) -> Result<usize, String> {
    let connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    Ok(connection.dgram_send_queue_byte_size())
}

/// Sends a DATAGRAM frame
#[rustler::nif]
pub fn connection_dgram_send(
    conn: ResourceArc<ConnectionResource>,
    payload: Binary,
) -> Result<usize, String> {
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    connection
        .dgram_send(payload.as_slice())
        .map(|_| payload.len())
        .map_err(|e| match e {
            quiche::Error::Done => "done".to_string(),
            quiche::Error::InvalidState => "done".to_string(),
            _ => format!("Datagram send error: {}", quiche_error_to_string(e)),
        })
}

/// Receives a queued DATAGRAM frame
#[rustler::nif]
pub fn connection_dgram_recv<'a>(
    env: rustler::Env<'a>,
    conn: ResourceArc<ConnectionResource>,
    max_len: usize,
) -> Result<rustler::Binary<'a>, String> {
    if max_len == 0 {
        return Err("max_len must be greater than zero".to_string());
    }
    let mut connection = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let mut binary =
        OwnedBinary::new(max_len).ok_or_else(|| "Failed to allocate binary".to_string())?;
    let buf = binary.as_mut_slice();

    match connection.dgram_recv(buf) {
        Ok(len) => {
            if len < max_len && !binary.realloc(len) {
                return Err("Failed to shrink binary".to_string());
            }
            Ok(binary.release(env))
        }
        Err(quiche::Error::Done) => Err("done".to_string()),
        Err(e) => Err(format!(
            "Datagram recv error: {}",
            quiche_error_to_string(e)
        )),
    }
}
