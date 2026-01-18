use crate::resources::{ConnectionResource, H3ConfigResource, H3ConnectionResource};
use quiche::h3::NameValue;
use rustler::{Binary, Encoder, Env, OwnedBinary, ResourceArc, Term};

rustler::atoms! {
    h3_headers,
    data,
    finished,
    reset,
    goaway,
    priority_update,
}

enum H3Event {
    Headers {
        headers: Vec<(Vec<u8>, Vec<u8>)>,
        more_frames: bool,
    },
    Data,
    Finished,
    Reset { error_code: u64 },
    GoAway { id: u64 },
    PriorityUpdate,
}

impl Encoder for H3Event {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            H3Event::Headers {
                headers: header_list,
                more_frames,
            } => {
                let headers: Vec<(Binary, Binary)> = header_list
                    .iter()
                    .map(|(name, value)| (to_binary(env, name), to_binary(env, value)))
                    .collect();
                (h3_headers(), headers, *more_frames).encode(env)
            }
            H3Event::Data => data().encode(env),
            H3Event::Finished => finished().encode(env),
            H3Event::Reset { error_code } => (reset(), *error_code).encode(env),
            H3Event::GoAway { id } => (goaway(), *id).encode(env),
            H3Event::PriorityUpdate => priority_update().encode(env),
        }
    }
}

fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut owned =
        OwnedBinary::new(bytes.len()).expect("Failed to allocate binary for header");
    owned.as_mut_slice().copy_from_slice(bytes);
    Binary::from_owned(owned, env)
}

fn build_headers(headers: Vec<(Binary, Binary)>) -> Vec<quiche::h3::Header> {
    headers
        .into_iter()
        .map(|(name, value)| quiche::h3::Header::new(name.as_slice(), value.as_slice()))
        .collect()
}

fn h3_error_to_string(err: quiche::h3::Error) -> String {
    format!("{:?}", err)
}

#[rustler::nif]
pub fn h3_config_new() -> Result<ResourceArc<H3ConfigResource>, String> {
    quiche::h3::Config::new()
        .map(|config| {
            ResourceArc::new(H3ConfigResource {
                inner: std::sync::Arc::new(std::sync::Mutex::new(config)),
            })
        })
        .map_err(|e| format!("Failed to create H3 config: {:?}", e))
}

#[rustler::nif]
pub fn h3_config_set_max_field_section_size(
    config: ResourceArc<H3ConfigResource>,
    v: u64,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    cfg.set_max_field_section_size(v);
    Ok(())
}

#[rustler::nif]
pub fn h3_config_set_qpack_max_table_capacity(
    config: ResourceArc<H3ConfigResource>,
    v: u64,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    cfg.set_qpack_max_table_capacity(v);
    Ok(())
}

#[rustler::nif]
pub fn h3_config_set_qpack_blocked_streams(
    config: ResourceArc<H3ConfigResource>,
    v: u64,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    cfg.set_qpack_blocked_streams(v);
    Ok(())
}

#[rustler::nif]
pub fn h3_config_enable_extended_connect(
    config: ResourceArc<H3ConfigResource>,
    enabled: bool,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    cfg.enable_extended_connect(enabled);
    Ok(())
}

#[rustler::nif]
pub fn h3_config_set_additional_settings(
    config: ResourceArc<H3ConfigResource>,
    settings: Vec<(u64, u64)>,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    cfg.set_additional_settings(settings)
        .map_err(|e| format!("Failed to set additional settings: {:?}", e))
}

#[rustler::nif]
pub fn h3_conn_new_with_transport(
    conn: ResourceArc<ConnectionResource>,
    h3_config: ResourceArc<H3ConfigResource>,
) -> Result<ResourceArc<H3ConnectionResource>, String> {
    let mut quic_conn = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    let cfg = h3_config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    quiche::h3::Connection::with_transport(&mut *quic_conn, &*cfg)
        .map(|h3_conn| {
            ResourceArc::new(H3ConnectionResource {
                inner: std::sync::Arc::new(std::sync::Mutex::new(h3_conn)),
            })
        })
        .map_err(|e| format!("Failed to create H3 connection: {:?}", e))
}

#[rustler::nif]
pub fn h3_conn_poll(
    conn: ResourceArc<ConnectionResource>,
    h3_conn: ResourceArc<H3ConnectionResource>,
) -> Result<(u64, H3Event), String> {
    let mut quic_conn = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    let mut h3_conn = h3_conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    match h3_conn.poll(&mut *quic_conn) {
        Ok((stream_id, event)) => {
            let event = match event {
                quiche::h3::Event::Headers { list, more_frames } => H3Event::Headers {
                    headers: list
                        .iter()
                        .map(|h| (h.name().to_vec(), h.value().to_vec()))
                        .collect(),
                    more_frames,
                },
                quiche::h3::Event::Data => H3Event::Data,
                quiche::h3::Event::Finished => H3Event::Finished,
                quiche::h3::Event::Reset(error_code) => H3Event::Reset { error_code },
                quiche::h3::Event::GoAway => H3Event::GoAway { id: stream_id },
                quiche::h3::Event::PriorityUpdate => H3Event::PriorityUpdate,
            };
            Ok((stream_id, event))
        }
        Err(quiche::h3::Error::Done) => Err("done".to_string()),
        Err(e) => Err(format!("H3 poll error: {}", h3_error_to_string(e))),
    }
}

#[rustler::nif]
pub fn h3_send_request(
    conn: ResourceArc<ConnectionResource>,
    h3_conn: ResourceArc<H3ConnectionResource>,
    headers: Vec<(Binary, Binary)>,
    fin: bool,
) -> Result<u64, String> {
    let mut quic_conn = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    let mut h3_conn = h3_conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let headers = build_headers(headers);
    h3_conn
        .send_request(&mut *quic_conn, &headers, fin)
        .map_err(|e| format!("H3 send_request error: {}", h3_error_to_string(e)))
}

#[rustler::nif]
pub fn h3_send_response(
    conn: ResourceArc<ConnectionResource>,
    h3_conn: ResourceArc<H3ConnectionResource>,
    stream_id: u64,
    headers: Vec<(Binary, Binary)>,
    fin: bool,
) -> Result<(), String> {
    let mut quic_conn = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    let mut h3_conn = h3_conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let headers = build_headers(headers);
    h3_conn
        .send_response(&mut *quic_conn, stream_id, &headers, fin)
        .map_err(|e| format!("H3 send_response error: {}", h3_error_to_string(e)))
}

#[rustler::nif]
pub fn h3_send_body(
    conn: ResourceArc<ConnectionResource>,
    h3_conn: ResourceArc<H3ConnectionResource>,
    stream_id: u64,
    body: Binary,
    fin: bool,
) -> Result<(), String> {
    let mut quic_conn = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    let mut h3_conn = h3_conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    h3_conn
        .send_body(&mut *quic_conn, stream_id, body.as_slice(), fin)
        .map(|_| ())
        .map_err(|e| format!("H3 send_body error: {}", h3_error_to_string(e)))
}

#[rustler::nif]
pub fn h3_recv_body<'a>(
    env: Env<'a>,
    conn: ResourceArc<ConnectionResource>,
    h3_conn: ResourceArc<H3ConnectionResource>,
    stream_id: u64,
    max_bytes: usize,
) -> Result<Binary<'a>, String> {
    let mut quic_conn = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    let mut h3_conn = h3_conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let mut binary =
        OwnedBinary::new(max_bytes).ok_or_else(|| "Failed to allocate binary".to_string())?;
    match h3_conn.recv_body(&mut *quic_conn, stream_id, binary.as_mut_slice()) {
        Ok(len) => {
            if len < max_bytes && !binary.realloc(len) {
                return Err("Failed to shrink binary".to_string());
            }
            Ok(Binary::from_owned(binary, env))
        }
        Err(quiche::h3::Error::Done) => Err("done".to_string()),
        Err(e) => Err(format!("H3 recv_body error: {}", h3_error_to_string(e))),
    }
}

#[rustler::nif]
pub fn h3_send_goaway(
    conn: ResourceArc<ConnectionResource>,
    h3_conn: ResourceArc<H3ConnectionResource>,
    stream_id: u64,
) -> Result<(), String> {
    let mut quic_conn = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    let mut h3_conn = h3_conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    h3_conn
        .send_goaway(&mut *quic_conn, stream_id)
        .map_err(|e| format!("H3 send_goaway error: {}", h3_error_to_string(e)))
}

#[rustler::nif]
pub fn h3_extended_connect_enabled_by_peer(
    h3_conn: ResourceArc<H3ConnectionResource>,
) -> Result<bool, String> {
    let h3_conn = h3_conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    Ok(h3_conn.extended_connect_enabled_by_peer())
}

#[rustler::nif]
pub fn h3_dgram_enabled_by_peer(
    conn: ResourceArc<ConnectionResource>,
    h3_conn: ResourceArc<H3ConnectionResource>,
) -> Result<bool, String> {
    let quic_conn = conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    let h3_conn = h3_conn
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;
    Ok(h3_conn.dgram_enabled_by_peer(&*quic_conn))
}
