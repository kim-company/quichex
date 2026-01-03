# Repository Guidelines

## Project Structure & Module Organization
Elixir application sources live under `lib/`, with top-level APIs in `lib/quichex.ex` and core modules grouped in `lib/quichex/` (e.g., `connection.ex`, `listener.ex`, `handler/`). Rustler NIFs are under `native/quichex_nif/` and produce shared objects in `priv/native/`. Tests mirror the structure inside `test/`, with helpers in `test/support/`, while assets like TLS fixtures reside in `priv/`. Example scripts for manual flows live in `scripts/`.

## Build, Test, and Development Commands
Install dependencies with `mix deps.get`, compile via `mix compile`, and build docs using `mix docs`. Run the default suite (`mix test`) or target layers: `mix test --exclude external` for fast unit coverage, `mix test test/quichex/listener_integration_test.exs` for internal listener checks, and `mix test --include external` when you have internet access. Format Elixir with `mix format`. For the Rust crate, run `cargo fmt --manifest-path native/quichex_nif/Cargo.toml` and `cargo clippy --manifest-path native/quichex_nif/Cargo.toml`.

## Coding Style & Naming Conventions
Follow idiomatic Elixir: two-space indentation, pipe-friendly function chains, and `@doc`/`@spec` pairs for all public APIs. Leverage `mix format` before sending changes and keep module names under `Quichex.*`. Tests and helpers should use snake_case filenames like `connection_test.exs`. Rust code must keep all byte buffers as `rustler::Binary` (see `CLAUDE.md`) and follow cargo fmt/clippy with warnings treated seriously.

## Testing Guidelines
Use ExUnit with async unit tests by default; limit async work when touching shared supervisors (see `test/quichex/listener_integration_test.exs`). Prefer colocating tests alongside the module namespace under `test/quichex/`. Every new feature needs unit coverage plus integration coverage when it touches the supervision tree or QUIC I/O; mirror the commands listed in `TESTING.md` and state which were run in your PR. External tests (`--include external`) must only run when network access is available, but keep them green before merging.

## Commit & Pull Request Guidelines
Commits follow the short, imperative style already in the log (e.g., “Add telemetry (connection, streams)”). Use focused commits that touch Elixir and Rust pieces separately when possible, reference issue IDs in the body, and avoid noise. Pull requests should summarize the change, link to relevant sections of `PLAN.md` or issues, list the commands executed (tests, formatters, docs), and include screenshots/logs when altering telemetry or CLI output. Note any impacts on NIF APIs or TLS fixtures so reviewers can double-check deployments.

## Security & Native Integration Tips
Do not commit new certificates or secrets—`priv/cert.crt` and `priv/cert.key` exist solely for tests. When adjusting native code, keep parity between `lib/quichex/native.ex` stubs and `native/quichex_nif/src/` implementations, and rerun `mix compile` so the refreshed `.so` lands in `priv/native/`. Document any new environment variables in `config/*.exs` and verify they default safely for production builds.
