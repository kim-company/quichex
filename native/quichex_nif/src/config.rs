use crate::resources::ConfigResource;
use rustler::ResourceArc;
use std::sync::{Arc, Mutex};

/// Creates a new QUIC configuration with the specified version
#[rustler::nif]
pub fn config_new(version: u32) -> Result<ResourceArc<ConfigResource>, String> {
    quiche::Config::new(version)
        .map(|config| {
            ResourceArc::new(ConfigResource {
                inner: Arc::new(Mutex::new(config)),
            })
        })
        .map_err(|e| format!("Failed to create config: {:?}", e))
}

/// Sets the application protocols (ALPN)
#[rustler::nif]
pub fn config_set_application_protos(
    config: ResourceArc<ConfigResource>,
    protos: Vec<String>,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    // Convert Vec<String> to Vec<&[u8]> as quiche expects
    let proto_refs: Vec<&[u8]> = protos.iter().map(|s| s.as_bytes()).collect();

    cfg.set_application_protos(&proto_refs)
        .map_err(|e| format!("Failed to set application protos: {:?}", e))
}

/// Sets the maximum idle timeout in milliseconds
#[rustler::nif]
pub fn config_set_max_idle_timeout(
    config: ResourceArc<ConfigResource>,
    millis: u64,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.set_max_idle_timeout(millis);
    Ok(())
}

/// Sets the initial maximum bidirectional streams
#[rustler::nif]
pub fn config_set_initial_max_streams_bidi(
    config: ResourceArc<ConfigResource>,
    v: u64,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.set_initial_max_streams_bidi(v);
    Ok(())
}

/// Sets the initial maximum unidirectional streams
#[rustler::nif]
pub fn config_set_initial_max_streams_uni(
    config: ResourceArc<ConfigResource>,
    v: u64,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.set_initial_max_streams_uni(v);
    Ok(())
}

/// Sets the initial maximum data (connection-level flow control)
#[rustler::nif]
pub fn config_set_initial_max_data(
    config: ResourceArc<ConfigResource>,
    v: u64,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.set_initial_max_data(v);
    Ok(())
}

/// Sets the initial maximum stream data for local bidirectional streams
#[rustler::nif]
pub fn config_set_initial_max_stream_data_bidi_local(
    config: ResourceArc<ConfigResource>,
    v: u64,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.set_initial_max_stream_data_bidi_local(v);
    Ok(())
}

/// Sets the initial maximum stream data for remote bidirectional streams
#[rustler::nif]
pub fn config_set_initial_max_stream_data_bidi_remote(
    config: ResourceArc<ConfigResource>,
    v: u64,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.set_initial_max_stream_data_bidi_remote(v);
    Ok(())
}

/// Sets the initial maximum stream data for unidirectional streams
#[rustler::nif]
pub fn config_set_initial_max_stream_data_uni(
    config: ResourceArc<ConfigResource>,
    v: u64,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.set_initial_max_stream_data_uni(v);
    Ok(())
}

/// Sets whether to verify the peer's certificate
#[rustler::nif]
pub fn config_verify_peer(
    config: ResourceArc<ConfigResource>,
    verify: bool,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.verify_peer(verify);
    Ok(())
}

/// Loads the certificate chain from a PEM file
#[rustler::nif]
pub fn config_load_cert_chain_from_pem_file(
    config: ResourceArc<ConfigResource>,
    path: String,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.load_cert_chain_from_pem_file(&path)
        .map_err(|e| format!("Failed to load cert chain: {:?}", e))
}

/// Loads the private key from a PEM file
#[rustler::nif]
pub fn config_load_priv_key_from_pem_file(
    config: ResourceArc<ConfigResource>,
    path: String,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.load_priv_key_from_pem_file(&path)
        .map_err(|e| format!("Failed to load private key: {:?}", e))
}

/// Loads trusted CA certificates from a PEM file
#[rustler::nif]
pub fn config_load_verify_locations_from_file(
    config: ResourceArc<ConfigResource>,
    path: String,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.load_verify_locations_from_file(&path)
        .map_err(|e| format!("Failed to load verify locations: {:?}", e))
}

/// Sets the congestion control algorithm
#[rustler::nif]
pub fn config_set_cc_algorithm(
    config: ResourceArc<ConfigResource>,
    algo: String,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    let cc_algo = match algo.to_lowercase().as_str() {
        "reno" => quiche::CongestionControlAlgorithm::Reno,
        "cubic" => quiche::CongestionControlAlgorithm::CUBIC,
        "bbr" => quiche::CongestionControlAlgorithm::BBR,
        "bbr2" => quiche::CongestionControlAlgorithm::BBR2,
        _ => return Err(format!("Unknown congestion control algorithm: {}", algo)),
    };

    cfg.set_cc_algorithm(cc_algo);
    Ok(())
}

/// Enables or disables QUIC datagrams
#[rustler::nif]
pub fn config_enable_dgram(
    config: ResourceArc<ConfigResource>,
    enabled: bool,
    recv_queue_len: usize,
    send_queue_len: usize,
) -> Result<(), String> {
    let mut cfg = config
        .inner
        .lock()
        .map_err(|e| format!("Lock error: {}", e))?;

    cfg.enable_dgram(enabled, recv_queue_len, send_queue_len);
    Ok(())
}
