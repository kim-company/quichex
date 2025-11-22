mod config;
mod connection;
mod resources;
mod types;

// Re-export NIFs from submodules for Rustler auto-discovery
#[allow(unused_imports)]
pub use config::*;
#[allow(unused_imports)]
pub use connection::*;

#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

rustler::init!("Elixir.Quichex.Native", load = resources::on_load);
