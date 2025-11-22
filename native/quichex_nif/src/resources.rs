use rustler::{Env, Term};
use std::sync::{Arc, Mutex};

/// Wrapper for quiche::Config with thread-safe reference counting
pub struct ConfigResource {
    pub inner: Arc<Mutex<quiche::Config>>,
}

/// Wrapper for quiche::Connection with thread-safe reference counting
pub struct ConnectionResource {
    pub inner: Arc<Mutex<quiche::Connection>>,
}

/// Load resources - called when NIF library is loaded
pub fn on_load(env: Env, _load_info: Term) -> bool {
    rustler::resource!(ConfigResource, env);
    rustler::resource!(ConnectionResource, env);
    true
}
