mod config;
mod resources;

#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

rustler::init!("Elixir.Quichex.Native", load = resources::on_load);
