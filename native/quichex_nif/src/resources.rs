use rustler::{Env, Term};
use std::collections::HashSet;
use std::sync::{Arc, Mutex};

/// Wrapper for quiche::Config with thread-safe reference counting
pub struct ConfigResource {
    pub inner: Arc<Mutex<quiche::Config>>,
}

/// Wrapper for quiche::Connection with thread-safe reference counting
pub struct ConnectionResource {
    pub inner: Arc<Mutex<quiche::Connection>>,
    pub known_streams: Arc<Mutex<HashSet<u64>>>,
}

/// Load resources - called when NIF library is loaded
#[allow(non_local_definitions)]
pub fn on_load(env: Env, _load_info: Term) -> bool {
    let _ = rustler::resource!(ConfigResource, env);
    let _ = rustler::resource!(ConnectionResource, env);
    true
}
