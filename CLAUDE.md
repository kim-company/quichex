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
- **Quichex.Connection (gen_statem)**: Manages individual QUIC connections using gen_statem. Each connection runs in its own process for fault isolation and concurrency. States: `:init`, `:handshaking`, `:connected`, `:closed`. State transitions and side effects handled inline for direct data flow.
- **Quichex.State**: Pure functional connection state management struct.
- **Quichex.StreamState**: Pure functional stream state (FIN flags, byte counters, flow control).
- **Quichex.Handler**: Behaviour for handling connection and stream events with custom logic. Handlers can return actions (send data, refuse streams, etc.) that are executed immediately.
- **Quichex.Handler.Default**: Default handler that sends messages to controlling process (imperative API).
- **Quichex.Listener (GenServer)**: Accepts incoming QUIC connections on the server side. Routes packets to appropriate connection processes.
- **Quichex.Config**: Struct and builder pattern for QUIC configuration (application protocols, flow control, congestion control, TLS settings).

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
- Each QUIC connection is a gen_statem process with simplified inline state management
- State machine states: `:init` → `:handshaking` → `:connected` → `:closed`
- State transitions and side effects (UDP I/O, timeouts) handled inline for direct data flow
- Pure functional helpers for complex state transformations
- Listener is a GenServer that spawns connection processes
- Supervision tree ensures fault tolerance and crash isolation
- Socket always in `{active, true}` mode for minimum latency
- Connection-level handlers receive callbacks for connection and stream events
- Handler.Default provides imperative API via messages, custom handlers enable declarative patterns
- Handlers can return actions that are executed immediately by the connection

### Message Protocol (Default Handler)
The default handler sends these messages to the controlling process:
- Connection lifecycle: `{:quic_connected, pid}`, `{:quic_connection_closed, pid, reason}`
- Stream events: `{:quic_stream_opened, pid, stream_id, direction, type}`, `{:quic_stream_readable, pid, stream_id}`
- Stream data: `{:quic_stream_data, pid, stream_id, data, fin}` (automatically read when readable)
- Stream finished: `{:quic_stream_finished, pid, stream_id}`

### Handler Actions
Handlers can return actions for declarative control:
- `{:read_stream, stream_id, opts}` - Read data from stream (triggers `handle_stream_data` callback)
- `{:send_data, stream_id, data, opts}` - Send data on stream
- `{:refuse_stream, stream_id, error_code}` - Refuse incoming stream
- `{:open_stream, opts}` - Open new stream
- `{:shutdown_stream, stream_id, direction, error_code}` - Shutdown stream
- `{:close_connection, error_code, reason}` - Close connection

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

### Elixir<->Rust API Conventions

**CRITICAL: All byte data must cross the boundary as `rustler::Binary`**

After comprehensive API audit, we've established these conventions:

1. **Byte Data**: Always use `Binary` (NEVER `Vec<u8>`)
   ```rust
   // ✅ Correct - returns binary in Elixir: <<1, 2, 3>>
   pub fn connection_source_id<'a>(
       env: rustler::Env<'a>,
       conn: ResourceArc<ConnectionResource>
   ) -> Result<rustler::Binary<'a>, String>

   // ❌ Wrong - returns confusing list in Elixir: [1, 2, 3]
   pub fn bad_example() -> Result<Vec<u8>, String>
   ```

2. **Text Data**: Use `String` for human-readable text
   ```rust
   pub fn connection_trace_id(conn: ResourceArc<ConnectionResource>) -> Result<String, String>
   ```

3. **Structured Data**: Use Erlang terms (tuples, maps, custom structs with `NifStruct` derive)
   ```rust
   pub fn connection_send<'a>(env: Env<'a>, conn: ResourceArc<ConnectionResource>)
       -> Result<(Binary<'a>, SendInfo), String>
   ```

**Performance Characteristics**:
- **Small data (<64 bytes)**: Binary has ~5% overhead vs Vec<u8>
- **Large data (>1KB)**: Binary is 10-100x faster (zero-copy, reference counted)
- **Rule of thumb**: Always use Binary for consistency and future-proofing

**Examples from codebase**:
- `connection_close(reason: Binary)` - accepts binary reason string
- `connection_send()` - returns binary packet data
- `connection_stream_recv()` - returns binary stream data
- `connection_source_id()` - returns binary connection ID
- `connection_peer_cert()` - returns `Vec<Binary>` for certificate chain

## Project Status

**Current Status**: Architecture Simplified - Inline State Transitions ✅

The project has a clean, simplified architecture with direct data flow:

- **Architecture**: gen_statem with inline state transitions and side effects
- **Simplicity**: Direct packet processing, no action queue, immediate execution
- **Handler System**: Connection-level handlers with optional action returns
- **Test Coverage**: 74/75 tests passing (98.7% pass rate)
- **API Consistency**: All Elixir<->Rust byte data uses Binary (zero-copy performance)

### Recent Work (Dec 2025)

✅ **Architecture Simplification**
- Merged StateMachine into Connection (~350 lines removed)
- Removed Action queue pattern for immediate side effect execution
- Simplified data flow: UDP packet → Process inline → Send response
- Handler actions executed immediately (send data, refuse streams, etc.)

✅ **Handler Enhancements**
- Handlers can return actions: `{:ok, state, actions}`
- Available actions: read_stream, send_data, refuse_stream, open_stream, close_connection, shutdown_stream
- Actions executed immediately by connection for direct feedback
- Declarative stream reading: handlers request reads via actions, receive data via callbacks
- Handler.Default auto-reads streams and sends `:quic_stream_data` messages

✅ **Active Mode Only**
- Socket always in `{active, true}` mode for minimum latency
- Immediate data delivery, no buffering
- Users implement buffering in custom handlers if needed

### Implementation Phases

✅ **Phase 1-2: Functional Core & gen_statem**
- Pure functional state management (State, StreamState)
- Migrated from GenServer to gen_statem with state_functions callback mode
- Connection handles protocol, Handlers handle application logic

✅ **Phase 3: Architecture Simplification**
- Merged StateMachine logic into Connection for clarity
- Removed action queue for immediate execution
- Enhanced Handler behaviour with action returns
- Maintained functional helpers for complex transformations

### Milestones (see PLAN.md)

1. ✅ Project Scaffolding
2. ✅ Config and Core NIFs
3. ✅ Client Connection Establishment
4. ✅ Stream Operations (simplified architecture)
5. ⏳ Server-Side Listener
6. ⏳ Advanced Features (datagrams, migration, stats)
7. ⏳ Production Hardening

### Next Steps

**Immediate:**
- Milestone 5: Server-Side Listener (accept incoming connections)
- UDP I/O optimization (batched packet sending)
- More integration tests and examples

**Future:**
- Advanced features: datagrams, connection migration, path migration
- Performance optimization and benchmarking
- Production hardening (telemetry, observability, error recovery)

## Important Conventions

### Elixir Style
- Follow standard Elixir formatting (configured in `.formatter.exs`)
- Use gen_statem for complex state machines (Connection), GenServer for simpler processes
- Prefer functional helpers for complex state transformations, inline side effects for simplicity
- Prefer pipeline operators for configuration builders and data transformations
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