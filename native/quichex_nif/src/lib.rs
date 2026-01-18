mod config;
mod connection;
mod packet;
mod resources;
mod types;

// Re-export NIFs from submodules for Rustler auto-discovery
#[allow(unused_imports)]
pub use config::*;
#[allow(unused_imports)]
pub use connection::*;
#[allow(unused_imports)]
pub use packet::*;

rustler::init!("Elixir.Quichex.Native.Nif", load = resources::on_load);
