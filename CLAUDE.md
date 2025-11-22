# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Quichex is an Elixir library providing QUIC transport via Rustler bindings to cloudflare/quiche. The library leverages the BEAM's concurrency model where each QUIC connection runs in its own lightweight Elixir process, enabling massive concurrency with fault isolation.

## Development Commands

### Mix Commands
```bash
# Install dependencies
mix deps.get

# Compile the project
mix compile

# Run tests
mix test

# Run a single test file
mix test test/quichex_test.exs

# Run a specific test
mix test test/quichex_test.exs:10

# Format code
mix format

# Generate documentation
mix docs
```

### Rust Commands (for NIFs)
```bash
# Format Rust code in native/ directory
cargo fmt --manifest-path native/quichex_nif/Cargo.toml

# Run Clippy on Rust code
cargo clippy --manifest-path native/quichex_nif/Cargo.toml
```

### Code Quality Tools
```bash
# Run Dialyzer (when configured)
mix dialyzer

# Run Credo (when configured)
mix credo

# Run test coverage (when configured)
mix coveralls
```

## Architecture

The library follows a layered architecture:

### Layer 1: Application Layer
User applications (Phoenix, custom protocols) interact with the public API.

### Layer 2: Quichex Public API (Elixir)
- **Quichex.Connection (GenServer)**: Manages individual QUIC connections. Each connection runs in its own process for fault isolation and concurrency.
- **Quichex.Listener (GenServer)**: Accepts incoming QUIC connections on the server side. Routes packets to appropriate connection processes.
- **Quichex.Config**: Struct and builder pattern for QUIC configuration (application protocols, flow control, congestion control, TLS settings).
- **Quichex.Stream**: Abstraction for QUIC stream operations (bidirectional and unidirectional).

### Layer 3: Quichex.NIF (Rustler NIFs - Internal)
Rust NIFs wrap cloudflare/quiche functionality:
- `config_*` functions for configuration management
- `connection_*` functions for connection lifecycle and operations
- Resource management using Rustler's resource system

### Layer 4: cloudflare/quiche (Rust)
Battle-tested QUIC protocol implementation handling:
- QUIC protocol state machine
- TLS handshake (BoringSSL)
- Congestion control, flow control, loss recovery

### Layer 5: :gen_udp (Erlang)
UDP socket I/O for sending and receiving QUIC packets.

## Key Design Patterns

### Process Model
- Each QUIC connection is a GenServer process
- Listener is a GenServer that spawns connection processes
- Supervision tree ensures fault tolerance and crash isolation
- Active/passive modes similar to :gen_tcp/:gen_udp

### Message Protocol
When `active: true`, connections send messages to the controlling process:
- Connection lifecycle: `{:quic_connected, pid}`, `{:quic_connection_error, pid, reason}`, `{:quic_connection_closed, pid, error_code, reason}`
- Stream data: `{:quic_stream, pid, stream_id, data}`, `{:quic_stream_fin, pid, stream_id}`
- Datagrams: `{:quic_dgram, pid, data}`

### Resource Management
- Rust resources (Config, Connection) managed via Rustler's ResourceArc
- Resources automatically cleaned up when Elixir processes terminate
- Mutex protection for shared state between Elixir and Rust

### Error Handling
- All functions return `{:ok, result}` or `{:error, reason}` tuples
- GenServer crashes handled by supervision tree
- Connection failures notify controlling process before shutdown

## Development Workflow

### Adding New Features
1. Define the API in the appropriate Elixir module (Config, Connection, Listener)
2. Add NIF function stubs in `lib/quichex/nif.ex`
3. Implement Rust NIFs in `native/quichex_nif/src/`
4. Add tests in `test/`
5. Document with `@doc` and `@spec`

### Testing Strategy
- **Unit tests**: Test each NIF function and Elixir API in isolation
- **Integration tests**: Full client-server flows within the same VM
- **Interop tests**: Test against other QUIC implementations (quiche-client, quiche-server, public QUIC servers)
- **Property-based tests**: Use StreamData for randomized testing of stream operations

### Rust NIF Development
- NIFs should never panic - always return Result types
- Use proper error handling and map quiche::Error to Elixir errors
- Minimize data copying (use Binary references where possible)
- Thread safety: wrap resources in Arc<Mutex<>> when mutable state is shared

## Project Status

The project is in early development (Milestone 1 phase). The basic scaffolding exists but core functionality is not yet implemented. See PLAN.md for the complete roadmap with 7 milestones:

1. Project Scaffolding (current)
2. Config and Core NIFs
3. Client Connection Establishment
4. Stream Operations
5. Server-Side Listener
6. Advanced Features (datagrams, migration, stats)
7. Production Hardening

## Important Conventions

### Elixir Style
- Follow standard Elixir formatting (configured in `.formatter.exs`)
- Use GenServer for stateful processes
- Prefer pipeline operators for configuration builders
- Document all public functions with examples

### Rust Style
- Follow Rust conventions (use `cargo fmt` and `cargo clippy`)
- No panics in NIF functions - always return Results
- Use descriptive error messages for Elixir consumers

### Configuration
- Builder pattern for ergonomic configuration (chained setters)
- Sensible defaults for all config options
- Validate inputs at the Elixir layer before calling NIFs

## Dependencies and Tooling

### Required Tools
- Elixir 1.19+ (specified in mise.toml)
- Erlang/OTP 28+ (specified in mise.toml)
- Rust toolchain (for Rustler NIFs)

### Key Dependencies
- **rustler**: Elixir-Rust bridge for NIFs
- **cloudflare/quiche**: QUIC implementation (to be added as dependency)

## Future Considerations

- HTTP/3 support will be a separate library (`quichex_h3`)
- Focus is on transport layer, not application protocols
- Performance optimizations come after correctness is proven
- Zero-copy optimizations where possible
- Telemetry integration for observability
- we're traking progress in PLAN.md -- update it accordingly