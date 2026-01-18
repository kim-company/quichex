# Repository Guidelines

## Project Structure & Module Organization
- `lib/` holds the Elixir API modules (public surface under `Quichex.*`).
- `native/quichex_nif/` contains the Rustler NIF crate and QUIC bindings.
- `priv/` stores build artifacts loaded by Rustler at runtime.
- `test/` contains ExUnit tests and fixtures; helpers live in `test/support/`.
- `doc/` and `README.md` cover documentation and examples.

## Build, Test, and Development Commands
- `mise install` sets up the pinned toolchain from `mise.toml`.
- `mix deps.get` fetches Elixir dependencies.
- `mix compile` builds the Elixir project and the Rust NIF via Rustler.
- `mix test` runs the full ExUnit suite, including socket-based integration tests.
- `mix format` applies the repo formatter to `lib/`, `test/`, and config files.

## Coding Style & Naming Conventions
- Use `mix format` and two-space indentation for Elixir (`.ex`, `.exs`).
- Prefer module names under `Quichex.*` with `snake_case` filenames.
- Rust code follows standard `rustfmt` conventions; keep NIF APIs small and explicit.
- Keep return values idiomatic: `{:ok, value}` / `{:error, reason}`.

## Testing Guidelines
- Framework: ExUnit (Elixir). Tests live in `test/**/*_test.exs`.
- Keep new tests close to the public API they exercise (for NIFs, add Elixir-level tests).
- Run focused tests with `mix test test/quichex/native/connection_test.exs` when iterating.

## Commit & Pull Request Guidelines
- Commit history uses short, imperative summaries (e.g., "Improve testing").
- Keep commits scoped and explain user-facing changes in the PR description.
- Link related issues and include reproduction steps for bug fixes.
- For API changes, note compatibility impact and update `README.md` examples.

## Configuration & Tooling Notes
- Tool versions are pinned in `mise.toml` (Elixir/Erlang/Rust).
- Rust dependencies are managed in `native/quichex_nif/Cargo.toml`.
