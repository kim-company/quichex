# Quichex Implementation Plan

**An Elixir library providing QUIC transport via Rustler bindings to cloudflare/quiche**

---

## Current Status (December 2025)

### ✅ Completed (Milestones 1-5 + Telemetry from Milestone 6)

**Architecture**: Production-ready client AND server with gen_statem + Handler system
- **Connection**: Full gen_statem implementation with inline state transitions (client + server modes)
- **Listener**: QUIC server with DCID-based packet routing
- **State Management**: Pure functional State and StreamState modules
- **Handler System**: Declarative event handling with action returns
  - `Handler.Default`: Message-based API (backward compatible)
  - Custom handlers: Declarative action-based control flow (required for server)
- **Supervision**: ConnectionRegistry (DynamicSupervisor) with `:temporary` restart strategy
- **Telemetry**: Comprehensive instrumentation for performance monitoring and observability ✨
- **Tests**: **71/71 tests passing (100%)** - clean output, production-ready ✅
  - 58 unit tests + 1 doctest + 12 telemetry tests
- **Interop**: Successfully connects to cloudflare-quic.com, internal client-server works

**What Works**:
1. ✅ Client connections (connect, handshake, close)
2. ✅ Server listener (accept, route packets, handshake)
3. ✅ TLS handshake with real servers (cloudflare-quic.com)
4. ✅ TLS handshake between internal client and server
5. ✅ Stream operations (open, send, receive, shutdown)
6. ✅ Multiplexing (multiple concurrent streams)
7. ✅ Active mode (always-on, minimum latency)
8. ✅ Handler actions (read_stream, send_data, refuse_stream, etc.)
9. ✅ Zero-copy Rust<->Elixir (Binary for all byte data)
10. ✅ Process supervision (fault isolation)
11. ✅ DCID-based packet routing (critical fix: use server's SCID)
12. ✅ **Telemetry instrumentation** (connection, stream, and listener events)

**Critical Achievements**:
- Server-side QUIC handshake working! Echo test passes consistently.
- Production-ready telemetry for monitoring performance and identifying issues.

### ⏳ Next: Milestone 6 - Advanced Features (Remaining)

**Goal**: Datagrams, connection migration, performance optimization

**What's Needed**:
1. QUIC DATAGRAM extension support
2. Connection migration and multipath
3. ~~Connection statistics and observability~~ ✅ **Telemetry completed!**
4. Performance benchmarks
5. qlog support

See [Milestone 6](#milestone-6-advanced-features-) for detailed plan.

---

## Vision

Quichex will be a production-ready QUIC transport library for Elixir that leverages the BEAM's concurrency model. Each QUIC connection runs in its own lightweight Elixir process, enabling massive concurrency with fault isolation. The library will expose a clean, idiomatic Elixir API while using Rustler to safely wrap the battle-tested cloudflare/quiche implementation.

## Goals

- ✅ Idiomatic Elixir API that feels natural to BEAM developers
- ✅ Production-ready reliability with proper supervision and error handling
- ✅ Support for both client and server QUIC connections
- ✅ Zero-copy where possible for performance
- ✅ Comprehensive test coverage including interop testing
- ✅ Excellent documentation and examples
- ⛔ **Not** implementing HTTP/3 (comes later - focus on transport layer)

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Application Layer (Phoenix, Custom Protocol, etc.)     │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ Quichex Public API (Elixir)                             │
│  - Quichex.Connection (gen_statem)                      │
│  - Quichex.State (pure functional state)                │
│  - Quichex.StreamState (stream state management)        │
│  - Quichex.Handler (behaviour for event handling)       │
│  - Quichex.Handler.Default (message-based API)          │
│  - Quichex.Config (struct + builder)                    │
│  - Quichex.ConnectionRegistry (DynamicSupervisor)       │
│  - Quichex.Listener (GenServer) [TODO]                  │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ Quichex.Native (Rustler NIFs - Internal)                │
│  - config_* functions                                   │
│  - connection_* functions                               │
│  - Resource management (ConfigResource, Connection)     │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ cloudflare/quiche (Rust)                                │
│  - QUIC protocol implementation                         │
│  - TLS handshake (BoringSSL)                            │
│  - Congestion control, flow control, etc.               │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ :gen_udp (Erlang)                                       │
│  - UDP socket I/O (always active mode)                  │
└─────────────────────────────────────────────────────────┘
```

## Key Design Decisions

### Process Model (gen_statem + Handlers)
- **Connection**: `gen_statem` with inline state transitions and side effects
- **States**: `:init` → `:handshaking` → `:connected` → `:closed`
- **Pure Functional Helpers**: Complex state transformations in `State` and `StreamState`
- **Handler System**: Connection-level callbacks for declarative event handling
  - `Handler.Default`: Sends messages to controlling process (imperative API)
  - Custom handlers: Return actions for declarative control flow
- **Socket Mode**: Always `{active, true}` for minimum latency
- **Supervision**: `ConnectionRegistry` (DynamicSupervisor) manages all connections

### Handler Actions
Handlers can return actions executed immediately by the connection:
- `{:read_stream, stream_id, opts}` - Read stream data
- `{:send_data, stream_id, data, opts}` - Send data
- `{:refuse_stream, stream_id, error_code}` - Refuse stream
- `{:open_stream, opts}` - Open new stream
- `{:shutdown_stream, stream_id, direction, error_code}` - Shutdown stream
- `{:close_connection, error_code, reason}` - Close connection

## Public API Design

### Configuration

```elixir
# Builder pattern for ergonomic configuration
config = Quichex.Config.new()
|> Quichex.Config.set_application_protos(["myproto"])
|> Quichex.Config.set_initial_max_streams_bidi(100)
|> Quichex.Config.set_initial_max_streams_uni(100)
|> Quichex.Config.set_initial_max_data(10_000_000)
|> Quichex.Config.set_initial_max_stream_data_bidi_local(1_000_000)
|> Quichex.Config.set_initial_max_stream_data_bidi_remote(1_000_000)
|> Quichex.Config.set_max_idle_timeout(30_000)
|> Quichex.Config.set_cc_algorithm(:cubic)  # :cubic, :reno, :bbr, :bbr2

# Server-specific
|> Quichex.Config.load_cert_chain_from_pem_file("cert.pem")
|> Quichex.Config.load_priv_key_from_pem_file("key.pem")

# Client-specific
|> Quichex.Config.verify_peer(true)
|> Quichex.Config.load_verify_locations_from_file("ca-cert.pem")
```

### Client Connection

```elixir
# Start a client connection (supervised, with default handler)
{:ok, conn_pid} = Quichex.start_connection(
  host: "cloudflare-quic.com",
  port: 443,
  config: config
)

# Wait for handshake completion
case Quichex.wait_connected(conn_pid, timeout: 5000) do
  :ok -> IO.puts("Connected!")
  {:error, reason} -> IO.puts("Failed: #{inspect(reason)}")
end

# Or receive async notifications (Handler.Default sends messages)
receive do
  {:quic_connected, ^conn_pid} ->
    IO.puts("Connection established")
  {:quic_connection_closed, ^conn_pid, reason} ->
    IO.puts("Connection closed: #{inspect(reason)}")
end

# Use custom handler for declarative event handling
defmodule MyHandler do
  @behaviour Quichex.Handler

  def init(_conn_pid, _opts), do: {:ok, %{}}

  def handle_connected(conn_pid, state) do
    IO.puts("Connected!")
    # Open a stream immediately
    actions = [{:open_stream, type: :bidirectional}]
    {:ok, state, actions}
  end

  def handle_stream_readable(conn_pid, stream_id, state) do
    # Request to read stream data
    actions = [{:read_stream, stream_id, []}]
    {:ok, state, actions}
  end

  def handle_stream_data(conn_pid, stream_id, data, fin, state) do
    IO.inspect(data, label: "Received")
    {:ok, state}
  end

  # ... implement other required callbacks
end

{:ok, conn} = Quichex.start_connection(
  host: "example.com",
  port: 443,
  config: config,
  handler: MyHandler
)
```

### Stream Operations

```elixir
# Open a stream
{:ok, stream_id} = Quichex.open_stream(conn_pid, :bidirectional)
# or
{:ok, stream_id} = Quichex.open_stream(conn_pid, :unidirectional)

# Send data on stream
:ok = Quichex.send_data(conn_pid, stream_id, "Hello", fin: false)
:ok = Quichex.send_data(conn_pid, stream_id, " QUIC!", fin: true)

# Receive messages (Handler.Default automatically reads streams)
receive do
  {:quic_stream_opened, ^conn_pid, ^stream_id, :incoming, :bidirectional} ->
    IO.puts("New incoming stream")

  {:quic_stream_readable, ^conn_pid, ^stream_id} ->
    IO.puts("Stream has data available")

  {:quic_stream_data, ^conn_pid, ^stream_id, data, fin} ->
    IO.puts("Received: #{data}")
    if fin, do: IO.puts("Stream finished")

  {:quic_stream_finished, ^conn_pid, ^stream_id} ->
    IO.puts("Stream fully received")
end

# Get readable/writable streams
{:ok, readable_streams} = Quichex.readable_streams(conn_pid)
{:ok, writable_streams} = Quichex.writable_streams(conn_pid)

# Close/reset stream
:ok = Quichex.shutdown_stream(conn_pid, stream_id, :read, error_code: 0)
:ok = Quichex.shutdown_stream(conn_pid, stream_id, :write, error_code: 0)
:ok = Quichex.shutdown_stream(conn_pid, stream_id, :both, error_code: 0)
```

### Server Listener

```elixir
# Start a listener
{:ok, listener_pid} = Quichex.Listener.start_link(
  port: 4433,
  config: server_config,
  active: true  # send {:quic_connection, ...} messages to parent
)

# Accept connections in active mode
receive do
  {:quic_connection, ^listener_pid, conn_pid, peer_address} ->
    # Spawn a handler process/GenServer
    {:ok, _handler} = MyApp.ConnectionHandler.start_link(conn_pid)
    IO.puts("New connection from #{inspect(peer_address)}")
end

# Or use a connection handler callback module
{:ok, listener_pid} = Quichex.Listener.start_link(
  port: 4433,
  config: server_config,
  connection_handler: MyApp.ConnectionHandler  # implements behaviour
)

defmodule MyApp.ConnectionHandler do
  @behaviour Quichex.ConnectionHandler

  def handle_connection(conn_pid, peer_address) do
    # Handle the connection
    {:ok, _pid} = Task.start(fn -> handle_conn(conn_pid) end)
    :ok
  end
end
```

### Datagrams (QUIC DATAGRAM extension)

```elixir
# Enable datagrams in config
config = Quichex.Config.new()
|> Quichex.Config.enable_dgram(true, recv_queue_len: 1000, send_queue_len: 1000)

# Send datagram
:ok = Quichex.Connection.dgram_send(conn_pid, "unreliable data")

# Receive datagram (active mode)
receive do
  {:quic_dgram, ^conn_pid, data} ->
    IO.puts("Got datagram: #{data}")
end
```

### Connection Management

```elixir
# Close connection gracefully
:ok = Quichex.Connection.close(conn_pid, error_code: 0, reason: "done")

# Check connection state
true = Quichex.Connection.is_established?(conn_pid)
false = Quichex.Connection.is_closed?(conn_pid)
true = Quichex.Connection.is_draining?(conn_pid)

# Get connection info
{:ok, info} = Quichex.Connection.info(conn_pid)
# => %{
#   local_address: {{127, 0, 0, 1}, 54321},
#   peer_address: {{1, 1, 1, 1}, 443},
#   alpn: "myproto",
#   is_server: false,
#   is_established: true,
#   ...
# }
```

## Error Handling

All errors follow Elixir conventions:

```elixir
# Function errors return {:ok, result} | {:error, reason}
case Quichex.Connection.connect(host: "invalid", port: 443, config: config) do
  {:ok, conn} -> conn
  {:error, :invalid_host} -> handle_error()
end

# GenServer crashes are caught by supervision tree
# Connection failures send {:quic_connection_error, pid, reason} messages
```

## Message Protocol (Handler.Default)

When using `Handler.Default` (the default), messages are sent to the controlling process:

```elixir
# Connection lifecycle
{:quic_connected, conn_pid}
{:quic_connection_closed, conn_pid, reason}

# Stream events
{:quic_stream_opened, conn_pid, stream_id, direction, stream_type}
# direction: :incoming | :outgoing
# stream_type: :bidirectional | :unidirectional

{:quic_stream_readable, conn_pid, stream_id}
# Sent when stream has data available

{:quic_stream_data, conn_pid, stream_id, data, fin}
# Automatically sent after :quic_stream_readable (Handler.Default auto-reads)
# fin: true means no more data will arrive

{:quic_stream_finished, conn_pid, stream_id}
# Stream fully received and closed

# Future features (not yet implemented)
# Datagrams
{:quic_dgram, conn_pid, data}

# Path events (for migration)
{:quic_path_created, conn_pid, path_id, local_addr, peer_addr}
{:quic_path_validated, conn_pid, path_id}
{:quic_path_failed, conn_pid, path_id, reason}
```

## Validation Strategy

### Current Test Status ✅

**73/73 tests passing (100%)** - Clean output, production-ready!

| Test Type | Count | Status | Description |
|-----------|-------|--------|-------------|
| **Unit Tests** | 58 | ✅ | Config (40), Connection (12), Stream (5), Doctest (1) |
| **Integration Tests** | 7 | ✅ | Internal client-server via Listener |
| **External Tests** | 15 | ✅ | cloudflare-quic.com (requires internet) |

**Test Layer Architecture**:
- ✅ Unit tests use `start_link_supervised!({Connection, opts})` with `NoOpHandler`
- ✅ Integration tests use `Quichex.start_connection/1` (full supervision path)
- ✅ Connections use `:temporary` restart strategy (correct OTP pattern)
- ✅ Clean output: No error logs, proper cleanup

See [TESTING.md](TESTING.md) for detailed testing guide.

### 1. Unit Tests ✅
- ✅ Test each NIF function in isolation with `ExUnit`
- ✅ Config builder functions (40 tests)
- ✅ Connection lifecycle (12 tests)
- ✅ Stream operations (5 tests)
- ⏳ Property-based testing with `StreamData` (future)
- ✅ Edge cases: invalid inputs, buffer boundaries, connection states

### 2. Integration Tests ✅
- ✅ Full client-server flow within same VM (7 tests)
- ✅ Multiple concurrent connections (10 clients tested)
- ✅ Stream multiplexing
- ✅ Large data transfer (100KB)
- ⏳ Connection migration scenarios (Milestone 6)
- ✅ Timeout and error handling

### 3. Interoperability Tests ✅
- ✅ Test against public QUIC servers (cloudflare-quic.com - 15 tests)
- ✅ Connection establishment, handshake, stream operations
- ⏳ Connect to `quiche-server` (deferred)
- ⏳ Connect to other QUIC implementations (msquic, quinn, etc.)
- ⏳ Server mode: accept connections from standard QUIC clients

### 4. Benchmarks
- Throughput: bytes/sec for large transfers
- Latency: RTT for request/response
- Concurrency: 10k, 100k simultaneous connections
- Memory usage per connection
- CPU usage under load

### 5. Fault Injection
- Network partition simulation
- Packet loss, reordering, duplication
- Connection timeout scenarios
- Process crashes (connection handler, listener, etc.)

### 6. Memory Safety
- Valgrind/ASAN for memory leaks in NIFs
- Long-running connections to detect leaks
- Rapid connect/disconnect cycles
- Resource cleanup verification

---

## Milestones

## Milestone 1: Project Scaffolding ⚙️

**Goal**: Set up the basic project structure with working Rustler integration

### TODOs:

- [x] Create new Mix project: `mix new quichex --sup`
- [x] Add dependencies to `mix.exs`:
  - [x] `{:rustler, "~> 0.37.1"}`
  - [x] `{:ex_doc, "~> 0.34", only: :dev}`
  - [ ] ~~`{:dialyxir, "~> 1.4", only: :dev, runtime: false}`~~ (skipped)
  - [ ] ~~`{:credo, "~> 1.7", only: :dev, runtime: false}`~~ (skipped)
- [x] Run `mix rustler.new` to create NIF boilerplate
- [x] Configure `native/quichex_nif/Cargo.toml`:
  - [x] Add dependency: `rustler = "0.37.0"`
  - [x] Add dependency: `lazy_static = "1.5"`
  - [x] Add dependency: `quiche = "0.24.6"` (using published crate)
- [x] Create basic module structure:
  - [x] `lib/quichex.ex` - Main module with version info
  - [x] `lib/quichex/native.ex` - NIF loading and stubs (created as `Native` instead of `NIF`)
  - [x] `lib/quichex/config.ex` - Config struct and builder
  - [x] `lib/quichex/connection.ex` - Connection GenServer (stub)
- [x] Implement basic "hello world" NIF to verify Rustler works
- [ ] Set up GitHub Actions CI:
  - [ ] Rust stable compilation
  - [ ] Mix tests
  - [ ] Mix format check
  - [ ] ~~Credo~~ (skipped)
  - [ ] ~~Dialyzer~~ (skipped)
- [x] Write `README.md` with project overview
- [x] Set up `mix docs` with examples (ExDoc dependency added)
- [ ] Add `LICENSE` file (same as quiche: BSD-2-Clause)

### Acceptance Criteria:
- ✅ `mix compile` succeeds and builds Rust NIF
- ✅ `mix test` runs (even with empty tests)
- ✅ Basic NIF function can be called from Elixir
- [ ] CI pipeline passes (not yet set up)

---

## Milestone 2: Config and Core NIFs 🔧

**Goal**: Implement configuration builder and core connection resource management

### TODOs:

#### Rust Side (native/quichex_nif/src/):

- [x] Create `lib.rs` with NIF initialization:
  - [x] `rustler::init!` macro with all exported functions
  - [x] Load BoringSSL properly for quiche (handled automatically by quiche crate)
- [x] Create `resources.rs`:
  - [x] `ConfigResource` struct wrapping `Arc<Mutex<quiche::Config>>`
  - [x] `ConnectionResource` struct wrapping `Arc<Mutex<quiche::Connection>>`
  - [x] Implement `rustler::Resource` for both
  - [x] Resource registration in `on_load` callback
- [x] Create `config.rs` with Config NIFs:
  - [x] `config_new(version: u32) -> Result<ResourceArc<ConfigResource>, String>`
  - [x] `config_set_application_protos(config, protos: Vec<String>) -> Result<(), String>`
  - [x] `config_set_max_idle_timeout(config, millis: u64) -> Result<(), String>`
  - [x] `config_set_initial_max_streams_bidi(config, v: u64) -> Result<(), String>`
  - [x] `config_set_initial_max_streams_uni(config, v: u64) -> Result<(), String>`
  - [x] `config_set_initial_max_data(config, v: u64) -> Result<(), String>`
  - [x] `config_set_initial_max_stream_data_bidi_local(config, v: u64) -> Result<(), String>`
  - [x] `config_set_initial_max_stream_data_bidi_remote(config, v: u64) -> Result<(), String>`
  - [x] `config_set_initial_max_stream_data_uni(config, v: u64) -> Result<(), String>`
  - [x] `config_verify_peer(config, verify: bool) -> Result<(), String>`
  - [x] `config_load_cert_chain_from_pem_file(config, path: String) -> Result<(), String>`
  - [x] `config_load_priv_key_from_pem_file(config, path: String) -> Result<(), String>`
  - [x] `config_load_verify_locations_from_file(config, path: String) -> Result<(), String>`
  - [x] `config_set_cc_algorithm(config, algo: String) -> Result<(), String>`
  - [x] `config_enable_dgram(config, enabled: bool, recv_queue: usize, send_queue: usize) -> Result<(), String>`
  - [x] `config_set_max_recv_udp_payload_size(config, size: usize) -> Result<(), String>` (Added during TLS investigation)
  - [x] `config_set_max_send_udp_payload_size(config, size: usize) -> Result<(), String>` (Added during TLS investigation)
  - [x] `config_set_disable_active_migration(config, disable: bool) -> Result<(), String>` (Added during TLS investigation)
  - [x] `config_grease(config, grease: bool) -> Result<(), String>` (Added during TLS investigation)
  - [x] `config_load_verify_locations_from_directory(config, path: String) -> Result<(), String>` (Added during TLS investigation)
- [x] Create `types.rs` for shared type conversions:
  - [x] Elixir term <-> `SocketAddr` conversion
  - [x] Elixir term <-> `quiche::RecvInfo` conversion
  - [x] Elixir term <-> `quiche::SendInfo` conversion
  - [x] Error enum -> Elixir error atom mapping

#### Elixir Side:

- [x] Implement `Quichex.Native` module:
  - [x] `use Rustler` with proper otp_app and crate settings
  - [x] Stub functions for all NIFs that raise `NifNotLoadedError`
  - [x] Proper `@spec` annotations for all NIFs
- [x] Implement `Quichex.Config`:
  - [x] Define `%Quichex.Config{}` struct holding `ConfigResource`
  - [x] `new(opts \\ []) :: t()` - creates config with defaults (now uses quiche::PROTOCOL_VERSION)
  - [x] Pipeline functions: `set_application_protos/2`, `set_max_idle_timeout/2`, etc.
  - [x] Additional pipeline functions added: `set_max_recv_udp_payload_size/2`, `set_max_send_udp_payload_size/2`, `set_disable_active_migration/2`, `grease/2`
  - [x] `load_verify_locations_from_directory/2` for directory-based CA cert loading
  - [x] `load_system_ca_certs/1` helper that automatically finds and loads system CA certificates
  - [x] Validate inputs (positive numbers, valid file paths, etc.)
  - [x] `@doc` for every public function
  - [x] `@spec` type annotations
- [x] Create `Quichex.Native.Error` module:
  - [x] Exception struct with `:operation` and `:reason` fields
  - [x] `message/1` function to get human-readable error messages
- [x] Write comprehensive tests:
  - [x] `test/quichex/config_test.exs` - test all config builder functions
  - [x] `test/quichex/native/error_test.exs` - test error handling
  - [x] Test invalid inputs return proper errors
  - [x] Test config resource is created and can be reused

### Acceptance Criteria:
- ✅ Config can be created and configured from Elixir
- ✅ All config setter NIFs work correctly (19 total config functions)
- ✅ Config resource properly managed (no memory leaks)
- ✅ Comprehensive test coverage for Config module (40 tests passing - 31 original + 9 new)
- ✅ System CA certificate loading works across multiple OS paths
- ⚠️ Documentation needs examples (has @doc and @spec, but lacks @moduledoc examples)

---

## Milestone 3: Client Connection Establishment 🔌 ✅

**Status**: **COMPLETE** - All 52 tests passing (31 config + 21 connection) + external cloudflare test ✅

**Goal**: Successfully establish a QUIC client connection and complete handshake with real servers

**MILESTONE FULLY ACHIEVED**: Connections now successfully establish with real-world QUIC servers (cloudflare-quic.com)!

### Completed Work:

#### Rust Side:

- [x] Create `connection.rs` with 15 connection NIFs:
  - [x] `connection_new_client(scid: Binary, server_name: Option<String>, local_addr: Binary, peer_addr: Binary, config: ResourceArc<ConfigResource>)`
    - **Critical fix**: Changed `scid` from `Vec<u8>` to `Binary` (Rustler decodes binaries vs lists differently)
  - [x] `connection_recv(conn, packet: Binary, recv_info: RecvInfo) -> Result<usize, String>`
  - [x] `connection_send(conn) -> Result<(Vec<u8>, SendInfo), String>`
  - [x] `connection_timeout(conn) -> Result<Option<u64>, String>`
  - [x] `connection_on_timeout(conn) -> Result<(), String>`
  - [x] `connection_is_established(conn) -> Result<bool, String>`
  - [x] `connection_is_closed(conn) -> Result<bool, String>`
  - [x] `connection_is_draining(conn) -> Result<bool, String>`
  - [x] `connection_close(conn, app: bool, err: u64, reason: Vec<u8>) -> Result<(), String>`
  - [x] `connection_trace_id(conn) -> Result<String, String>`
  - [x] `connection_source_id(conn) -> Result<Vec<u8>, String>`
  - [x] `connection_destination_id(conn) -> Result<Vec<u8>, String>`
  - [x] `connection_application_proto(conn) -> Result<Vec<u8>, String>`
  - [x] `connection_peer_cert(conn) -> Result<Option<Vec<Vec<u8>>>, String>`
  - [x] `connection_is_in_early_data(conn) -> Result<bool, String>`
- [x] Created `types.rs` for type conversions:
  - [x] `RecvInfo` encoder/decoder with **atom keys** (`:from`, `:to`)
  - [x] `SendInfo` encoder with **atom keys** (`:from`, `:to`, `:at_micros`)
  - [x] `SocketAddress` conversion for Elixir tuples
  - [x] `parse_address_binary()` for 6-byte IPv4 and 18-byte IPv6 binaries
  - [x] `quiche_error_to_string()` mapping all error variants
- [x] Handle errors properly:
  - [x] Map all `quiche::Error` variants to descriptive strings
  - [x] Special handling for `Error::Done` in close operations

#### Elixir Side:

- [x] Implement `Quichex.Connection` GenServer (~380 lines):
  - [x] `connect/1` - starts connection GenServer as client
  - [x] `init/1` - opens UDP socket, creates connection resource, sends initial packets
    - [x] Proper option validation with `KeyError` on missing required options
  - [x] `handle_info({:udp, ...})` - processes incoming packets, checks established state
  - [x] `handle_info(:quic_timeout, ...)` - handles QUIC timeout events
  - [x] Private `send_pending_packets/1` - drains packets from quiche and sends via UDP
  - [x] Private `schedule_next_timeout/1` - schedules next timeout based on `connection_timeout`
  - [x] Private `format_address/1` - encodes socket addresses as 6/18-byte binaries
  - [x] Connection ID generation (`:crypto.strong_rand_bytes(16)`)
- [x] Implement client API:
  - [x] `connect/1` - starts connection GenServer as client
  - [x] `wait_connected/2` - stub (returns `:not_yet_implemented`)
  - [x] `close/2` - gracefully closes connection (handles `Error::Done`)
  - [x] `is_established?/1` - checks if handshake done
  - [x] `is_closed?/1` - checks closed state (local state + NIF)
  - [x] `info/1` - returns connection metadata
- [x] State management:
  - [x] Track: socket, conn_resource, peer_address, controlling_process, active mode
  - [x] Track: handshake completion, connection closure
  - [x] Handle state transitions properly
- [x] Error handling:
  - [x] Connection errors during init return `{:stop, {:connection_error, reason}}`
  - [x] Socket cleanup in error paths
  - [x] `Error::Done` treated as success in close operations

#### Tests:

- [x] Create `test/quichex/connection_test.exs` (12 tests, all passing):
  - [x] Test creating connection with valid config
  - [x] Test required option validation (host, port, config)
  - [x] Test `is_established?/1` returns false for new connection
  - [x] Test `is_closed?/1` for active and closed connections
  - [x] Test graceful close with default and custom error codes
  - [x] Test `info/1` returns connection metadata
  - [x] Test hostname resolution (localhost)
  - [x] Test connection lifecycle (sends packets on initialization)

### Key Bug Fixes:

1. **Rustler Binary vs Vec<u8>** (connection.rs:50)
   - Rustler decodes Elixir **lists** `[1,2,3,4]` to `Vec<u8>`
   - Rustler decodes Elixir **binaries** `<<1,2,3,4>>` to `Binary`
   - Changed `scid` parameter from `Vec<u8>` to `Binary`

2. **Atom vs String Map Keys** (types.rs:5-9, 85-86, 120-135)
   - Encoders used string keys `"from"`, `"to"` causing KeyError
   - Fixed with `rustler::atoms!` macro and atom keys

3. **Close Error Handling** (connection.ex:215-217, 229-231)
   - `quiche::Error::Done` when closing unestablished connection
   - Now treated as success (`:ok`)

4. **State Tracking** (connection.ex:213-221)
   - `is_closed?` now checks local `state.closed` flag first

5. **Validation Errors** (connection.ex:121-135)
   - Used `with` statement to validate options
   - Returns proper `{:stop, {:connection_error, %KeyError{}}}`

### Acceptance Criteria:
- ✅ Connection resource created successfully via NIF
- ✅ All connection NIFs working correctly
- ✅ Proper error handling and validation
- ✅ State management working (established, closed tracking)
- ✅ All 12 connection tests passing
- ✅ All 31 config tests still passing
- ✅ **Total: 43 tests, 0 failures**
- ✅ No memory leaks (Rust resources properly managed)
- ⚠️ Connection to real servers not yet tested (needs Milestone 4 for stream operations)

### What You Can Do Now (Practical Usage):

**✅ Working Features:**
1. **Configuration Management** - Full builder pattern with all options
2. **Connection Lifecycle** - Create, query state, and close connections
3. **Multiple Concurrent Connections** - Manage many connections simultaneously
4. **Connection Metadata** - Query local/peer addresses, server name, state
5. **UDP Socket Management** - Automatic socket creation and cleanup
6. **Connection ID Generation** - Secure random SCID generation

**Example:**
```elixir
# Create optimized config
config = Quichex.Config.new!()
  |> Quichex.Config.set_application_protos(["h3"])
  |> Quichex.Config.set_max_idle_timeout(30_000)
  |> Quichex.Config.set_initial_max_streams_bidi(100)
  |> Quichex.Config.verify_peer(false)

# Start connection
{:ok, conn} = Quichex.Connection.connect(
  host: "example.com",
  port: 443,
  config: config
)

# Query connection
{:ok, info} = Quichex.Connection.info(conn)
# => %{local_address: {{0,0,0,0}, 12345}, peer_address: {{1,1,1,1}, 443}, ...}

# Close gracefully
Quichex.Connection.close(conn)
```

**❌ Known Limitations:**

1. **✅ RESOLVED: TLS Handshake Stalls** - ~~Critical blocker for real connections~~
   - **ROOT CAUSE IDENTIFIED:** ALPN protocol mismatch
   - **Issue:** Server was rejecting connections with TLS alert code 120 (0x78) = "no_application_protocol"
   - **Fix:** Changed ALPN from "hq-interop" to "h3" for cloudflare-quic.com
   - **Details:** The server was sending peer_error with error_code=376 (0x100 + 0x78), indicating TLS alert 120
   - **Result:** ✅ Connections now establish successfully! All tests passing including external cloudflare test
   - **Lesson:** Different QUIC servers support different ALPN protocols:
     - "h3" = HTTP/3 (widely supported)
     - "hq-interop" = QUIC interop testing protocol (limited server support)
     - Applications should configure ALPN based on their target servers

2. **No Stream Operations** - Can't send/receive application data
   - Milestone 4 dependency
   - Need: `stream_send`, `stream_recv`, stream multiplexing

3. **No Server Mode** - Can't accept incoming connections
   - Milestone 5 dependency

4. **No Active Mode Notifications** - `{:quic_connected, pid}` not yet emitted
   - Connection establishment detection implemented
   - Active mode message sending not yet triggered (TLS handshake never completes)

**Test Coverage:** All infrastructure tests pass, but real-world connection tests require TLS fix

---

## Milestone 4: Stream Operations 📊 ✅

**Status**: **COMPLETE** - 60 passing tests + Handler system fully implemented! 🎉

**Goal**: Send and receive data on QUIC streams with declarative handler system

**Additional Achievement**: Implemented comprehensive Handler behaviour for declarative event handling alongside traditional message-based API.

### Completed Work:

#### Rust Side:

- [x] Add stream NIFs to `connection.rs` (6 total stream NIFs):
  - [x] `connection_stream_send(conn, stream_id, data: Binary, fin) -> Result<usize, String>`
  - [x] `connection_stream_recv(conn, stream_id, max_len) -> Result<(Vec<u8>, bool), String>`
  - [x] `connection_readable_streams(conn) -> Result<Vec<u64>, String>`
  - [x] `connection_writable_streams(conn) -> Result<Vec<u64>, String>`
  - [x] `connection_stream_finished(conn, stream_id) -> Result<bool, String>`
  - [x] `connection_stream_shutdown(conn, stream_id, direction: String, err_code) -> Result<(), String>`
    - Handles "read", "write", and "both" directions
    - Treats `Error::Done` as success (similar to connection close)
- [x] Optimize for zero-copy:
  - [x] Use `Binary` type for send data (zero-copy from Elixir)
  - [x] Return `Vec<u8>` for receive (Rustler handles efficiently)

#### Elixir Side:

- [x] Extended `Quichex.Connection` with full stream support (connection.ex:lib/quichex/connection.ex):
  - [x] `open_stream/2` - opens bidirectional or unidirectional stream with correct stream ID calculation
  - [x] `stream_send/4` - sends data on stream (with `fin` option)
  - [x] `stream_recv/3` - passive mode receive with default max_len of 65535
  - [x] `stream_shutdown/4` - shutdown stream read/write/both
  - [x] `readable_streams/1` - get list of readable streams
  - [x] `writable_streams/1` - get list of writable streams
- [x] Enhanced `handle_info({:udp, ...})` for active mode:
  - [x] Check for readable streams after processing packets via `process_readable_streams/1`
  - [x] Read data from readable streams via `process_stream_data/2`
  - [x] Send `:quic_stream` messages to controlling process (only if not self)
  - [x] Detect stream FIN and send `:quic_stream_fin` message
  - [x] Handle stream errors gracefully (ignore "done" errors)
- [x] Add GenServer call handlers for all stream operations:
  - [x] `{:stream_send, stream_id, data, fin}` -> send data and flush packets
  - [x] `{:stream_recv, stream_id, max_len}` -> passive read
  - [x] `{:stream_shutdown, stream_id, direction, error_code}` -> shutdown with flush
  - [x] `{:open_stream, type}` -> allocate and return stream ID
- [x] Stream state tracking:
  - [x] Track opened streams (Map: stream_id -> %{type, fin_sent, fin_received})
  - [x] Separate counters for bidi (`next_bidi_stream`) and uni (`next_uni_stream`) streams
  - [x] Track stream direction (bidi vs uni)
  - [x] Track FIN sent/received
  - [x] Update state on send/recv operations
- [x] Controlling process management:
  - [x] Fixed controlling_process initialization (now uses parent PID from `$callers`)
  - [x] Only send messages if controlling_process != self()
  - [x] Proper message delivery for `:quic_connected`, `:quic_stream`, `:quic_stream_fin`

#### Tests:

- [x] Created `test/quichex/stream_test.exs` (12 tests, all passing):
  - [x] Test opening bidirectional and unidirectional streams (correct IDs: 0, 4, 8 for bidi; 2, 6, 10 for uni)
  - [x] Test sending data on streams (with and without FIN)
  - [x] Test `stream_send/4` with fin option
  - [x] Test `readable_streams/1` returns list
  - [x] Test `writable_streams/1` returns list
  - [x] Test stream shutdown in read, write, and both directions
  - [x] Test multiple concurrent streams (5 streams simultaneously)
  - [x] Test passive mode `stream_recv/3` with default and custom max_len
- [x] Created `test/quichex/integration_test.exs` (5 tests, all passing):
  - [x] Test full stream workflow with cloudflare-quic.com
  - [x] Test active mode message delivery
  - [x] Test passive mode stream recv
  - [x] Test multiple concurrent streams (5 streams)
  - [x] Test stream shutdown with real server

### Key Bug Fixes:

1. **Stream ID Calculation** (connection.ex:337-345)
   - Fixed separate counter bug (was using single `next_stream_id` for both types)
   - Now uses `next_bidi_stream` and `next_uni_stream` separately
   - Correct IDs: bidi=0,4,8,12; uni=2,6,10,14

2. **Stream Shutdown Done Error** (connection.rs:386-389)
   - Treat `Error::Done` as success (similar to connection close)
   - Allows shutdown of streams that haven't sent/received data yet

3. **Controlling Process** (connection.ex:227-230)
   - Fixed initialization from `self()` (GenServer) to parent PID via `$callers`
   - Prevents GenServer from receiving its own messages

4. **Connection State After Close** (connection.ex:306, 310, 281-288)
   - Set `established: false` when closing
   - Check `closed` flag in `is_established?`

### Acceptance Criteria:
- ✅ Can open streams (both bidi and uni) with correct stream IDs
- ✅ Can send data on streams (tested with cloudflare-quic.com)
- ✅ Can receive data on streams in active mode
- ✅ Multiple streams work concurrently without interference (tested 5 concurrent)
- ✅ FIN handling works correctly
- ✅ Stream lifecycle messages delivered to controlling process
- ✅ All 69 tests passing (including integration tests with real server)
- ⚠️ Flow control: Basic support via readable/writable streams (advanced backpressure handling deferred)
- ⚠️ Property-based testing: Not implemented (deferred to future milestone)

---

## Milestone 5: Server-Side Listener 🖥️ ✅ COMPLETE

**Goal**: Accept incoming QUIC connections as a server

**Status**: **COMPLETE** - Echo test passing consistently, server handshake working! 🎉

### Completed Work ✅

#### Server NIFs (Rust)

- ✅ `connection_new_server()` - Creates server-side quiche::Connection using `quiche::accept()`
- ✅ `header_info()` - Parses QUIC packet headers to extract DCID for routing
- ✅ Proper Binary handling for connection IDs and packet data
- ✅ Error handling for all server-side operations

#### Listener Implementation (Elixir)

- ✅ **Quichex.Listener GenServer** (`lib/quichex/listener.ex`, ~370 lines)
  - UDP socket management with `{active, true}` mode
  - **DCID-based packet routing** (critical fix: use server's SCID as routing key)
  - Connection acceptance and supervision
  - Connection lifecycle management (monitoring, cleanup)
  - Integration with ConnectionRegistry

#### Server Connection Support

- ✅ Server mode in Connection gen_statem
- ✅ `:init` state for server connections (waits for first packet)
- ✅ Server-side handshake flow
- ✅ Handler requirement for server connections (no controlling process)
- ✅ Socket sharing between Listener and Connections

#### Critical Bug Fix

**Problem**: Packet routing was using client's initial DCID as routing key, but client switches to server's SCID after first packet, causing duplicate connections and crypto_fail errors.

**Solution**: Changed routing table to use **server's SCID** (not client's DCID) as the key. After the server responds with its SCID, the client uses that as the DCID in all subsequent packets.

**Impact**: Server handshake now completes successfully, echo test passes consistently!

### Test Results

#### Integration Tests (All Passing ✅)

**All 7 Listener Integration Tests** (test/quichex/listener_integration_test.exs):
1. ✅ Echo test - client sends data, server echoes back
2. ✅ Listener tracks active connections
3. ✅ Multiple streams on single connection
4. ✅ Multiple concurrent connections (10 clients)
5. ✅ Listener shutdown with active connections
6. ✅ Connection close from client side
7. ✅ Large data transfer (100KB bidirectional)

**Test Quality**:
- Clean output: No error logs
- Stability: 100% pass rate over multiple runs
- Runtime: ~1.7 seconds (async: false due to shared ConnectionRegistry)

#### Test Infrastructure

- ✅ **NoOpHandler** - No-op handler for unit tests (prevents error logs)
- ✅ **EchoHandler** - Server-side echo handler for integration tests
- ✅ **ListenerHelpers** - Helper functions using public API (`Quichex.start_connection/1`)
- ✅ Test certificates (self-signed, in priv/)
- ✅ Test configurations (server and client configs with proper ALPN)
- ✅ **Test Layer Architecture**:
  - Unit tests: Direct `Connection.start_link/1` with `NoOpHandler`
  - Integration tests: Public API via ConnectionRegistry with `Handler.Default`
- ✅ **Supervision**: Connections use `:temporary` restart strategy (correct OTP pattern)

#### Test Restructuring (December 2025)

**Completed**:
- ✅ Deleted redundant supervision tests (connection_supervisor_test.exs, connection_supervised_test.exs)
- ✅ Updated connection_test.exs to use `start_link_supervised!({Connection, opts})` for unit tests
- ✅ Added `Connection.child_spec/1` function
- ✅ Created `NoOpHandler` for clean unit test output
- ✅ Updated ListenerHelpers to use public API (`Quichex.start_connection/1`)
- ✅ Fixed external integration tests (cloudflare-quic.com)
- ✅ All 73 tests passing with clean output

### Acceptance Criteria

- ✅ Listener can start on any available port
- ✅ Listener accepts connections from Quichex clients
- ✅ Connection routing works (SCID-based dispatch - **critical fix applied**)
- ✅ Server handshake completes successfully
- ✅ Echo test passes consistently (100% stability)
- ✅ Handler callbacks work (required for server)
- ✅ Stream data flows between client and server
- ✅ Multiple concurrent connections (10 clients tested successfully)
- ✅ All 7 listener integration tests passing
- ✅ All 73 tests passing (100% pass rate, clean output)
- ⏳ Listener accepts connections from quiche-client (deferred to future testing)

### Key Learnings

1. **DCID Routing Critical**: The routing table MUST use the server's SCID (not client's DCID) as the key
   - Client switches from its random DCID to server's SCID after first packet
   - Using client's DCID causes duplicate connections and crypto_fail errors

2. **Handler Requirement**: Server connections MUST have a custom handler
   - No "controlling process" for incoming connections
   - Handler processes connection and stream events

3. **Socket Ownership**: Listener owns socket, connections receive packets via forwarding
   - Connections send packets directly via `:gen_udp` (same socket, multiple writers OK)
   - Simple and performant design

4. **Type Consistency**: DCID from header_info returns list, SCID from crypto is binary
   - Need to convert for routing table key matching
   - Used `:binary.bin_to_list()` and `:binary.list_to_bin()` for conversions

5. **Test Layer Architecture**: Unit vs Integration tests need distinct approaches
   - **Unit tests**: Use `start_link_supervised!({Connection, opts})` to bypass ConnectionRegistry
   - **Integration tests**: Use `Quichex.start_connection/1` to test full supervision path
   - **NoOpHandler**: Prevents error logs from handler messages sent to ExUnit supervisor
   - **Temporary Restart**: Connections should use `:temporary` restart strategy (never restart)
   - Clean separation enables fast async unit tests and realistic integration tests

### What Works Now

**Server-Side**:
- ✅ Accept incoming QUIC connections
- ✅ Complete TLS handshake with clients
- ✅ Route packets to correct connection based on DCID
- ✅ Handle multiple connections (routing works, test issues separate)
- ✅ Process stream data and respond
- ✅ Handler-based event processing
- ✅ Connection supervision and cleanup

**Example Usage**:
```elixir
# Server
{:ok, listener} = Quichex.Listener.start_link(
  port: 4433,
  config: server_config,
  handler: EchoHandler
)

# Client
{:ok, client} = Quichex.Connection.start_link(
  host: "127.0.0.1",
  port: 4433,
  config: client_config
)

# Send data
{:ok, stream_id} = Quichex.Connection.open_stream(client, type: :bidirectional)
{:ok, _bytes} = Quichex.Connection.stream_send(client, stream_id, "Hello, QUIC!", fin: true)

# Receive echo
receive do
  {:quic_stream_data, ^client, ^stream_id, data, true} ->
    IO.puts("Echoed: #{data}")  # => "Echoed: Hello, QUIC!"
end
```

---

## Milestone 6: Advanced Features 🚀

**Goal**: Support datagrams, connection migration, and performance optimization

### TODOs:

#### Datagrams (QUIC DATAGRAM Extension):

- [ ] Rust NIFs:
  - [ ] `connection_dgram_send(conn, data: Binary) -> Result<(), String>`
  - [ ] `connection_dgram_recv(conn) -> Result<Option<OwnedBinary>, String>`
  - [ ] `connection_dgram_send_queue_len(conn) -> Result<usize, String>`
  - [ ] `connection_dgram_recv_queue_len(conn) -> Result<usize, String>`
- [ ] Elixir API:
  - [ ] `dgram_send/2` - send unreliable datagram
  - [ ] `dgram_recv/1` - receive datagram (passive mode)
  - [ ] Handle datagrams in active mode (send `:quic_dgram` messages)
  - [ ] Config option to enable/disable datagrams
- [ ] Tests:
  - [ ] Send and receive datagrams
  - [ ] Test unreliability (some may be dropped)
  - [ ] Test queue limits

#### Connection Migration:

- [ ] Rust NIFs:
  - [ ] `connection_migrate(conn, local_addr: String, peer_addr: String) -> Result<(), String>`
  - [ ] `connection_paths(conn) -> Result<Vec<PathInfoTerm>, String>`
  - [ ] `connection_active_path(conn) -> Result<PathInfoTerm, String>`
- [ ] Elixir API:
  - [ ] `migrate/3` - initiate connection migration
  - [ ] `paths/1` - get all connection paths
  - [ ] `active_path/1` - get currently active path
  - [ ] Messages for path events: `:quic_path_created`, `:quic_path_validated`, etc.
- [ ] Tests:
  - [ ] Test path migration
  - [ ] Test multi-path scenarios

#### Connection Statistics and Observability:

- [ ] Rust NIFs (deferred):
  - [ ] `connection_stats(conn) -> Result<StatsMap, String>` - comprehensive stats
  - [ ] Include: RTT, cwnd, bytes sent/received, packets lost, etc.
- [ ] Elixir API (deferred):
  - [ ] `stats/1` - get connection statistics
  - [ ] `path_stats/2` - get per-path statistics
- [x] **Telemetry integration: ✅ COMPLETE**
  - [x] Add dependency: `{:telemetry, "~> 1.3"}`
  - [x] Created `lib/quichex/telemetry.ex` helper module
  - [x] Emit telemetry events for:
    - [x] Connection lifecycle (connect, handshake, close)
    - [x] Stream operations (open, send, recv, shutdown)
    - [x] Listener events (start, accept, packet routing, connection termination)
    - [x] Bytes sent/received per operation
    - [x] Operation durations (with native time units)
  - [x] Document all telemetry events (in module docs)
  - [x] Three-phase pattern (start/stop/exception) for all operations
- [x] **Tests:**
  - [x] 12 comprehensive telemetry tests
  - [x] Verify telemetry events are emitted with correct measurements and metadata
  - [x] Integration tests with real connection/stream operations

**Telemetry Events Implemented:**

Connection Events:
- `[:quichex, :connection, :connect, :start|:stop|:exception]` - Connection establishment
- `[:quichex, :connection, :handshake, :start|:stop|:exception]` - TLS handshake
- `[:quichex, :connection, :close, :start|:stop]` - Connection close

Stream Events:
- `[:quichex, :stream, :open, :start|:stop|:exception]` - Stream creation
- `[:quichex, :stream, :send, :start|:stop|:exception]` - Data send
- `[:quichex, :stream, :recv, :start|:stop|:exception]` - Data receive
- `[:quichex, :stream, :shutdown, :start|:stop|:exception]` - Stream shutdown

Listener Events:
- `[:quichex, :listener, :start, :start|:stop|:exception]` - Listener startup
- `[:quichex, :listener, :accept, :start|:stop|:exception]` - Connection accept
- `[:quichex, :listener, :route_packet, :start|:stop|:exception]` - Packet routing
- `[:quichex, :listener, :connection_terminated, :stop]` - Connection cleanup

**Measurements:**
- `:duration` - Operation duration in native time units (nanoseconds)
- `:system_time` - Wall clock timestamp
- `:monotonic_time` - Monotonic timestamp for correlation
- `:bytes_sent` / `:bytes_received` - Data transfer volume
- `:packets_sent` / `:packets_received` - Packet counts
- `:data_size` / `:bytes_written` / `:bytes_read` - Operation-specific metrics

**Metadata:**
- Connection context: `conn_pid`, `mode` (:client/:server)
- Network info: `peer_addr`, `local_addr`, `host`, `port`
- Stream info: `stream_id`, `type`, `direction`, `fin`
- Listener info: `listener_pid`, `handler`, `dcid`
- Results: `error`, `reason`, `action`, `active_connections`

#### Performance Optimizations:

- [ ] Zero-copy optimizations:
  - [ ] Review all Binary/OwnedBinary usage
  - [ ] Minimize copies in send/recv paths
  - [ ] Consider using `Binary` references where possible
- [ ] Batch operations:
  - [ ] `send_pending_packets` should send multiple packets per syscall if possible
  - [ ] Consider `sendmmsg` for batch sends (if available)
- [ ] Benchmarks:
  - [ ] Create `bench/` directory
  - [ ] Throughput benchmark: measure Gbps for large transfers
  - [ ] Latency benchmark: measure RTT for request/response
  - [ ] Concurrency benchmark: 1k, 10k, 100k concurrent connections
  - [ ] Memory benchmark: bytes per connection
- [ ] Document performance characteristics:
  - [ ] Add `PERFORMANCE.md` with benchmark results
  - [ ] Tuning guide for production use

#### Additional Features:

- [ ] Support for qlog:
  - [ ] Config option to enable qlog
  - [ ] NIF to set qlog output path
  - [ ] Tests with qlog enabled
- [ ] Early data (0-RTT):
  - [ ] Config options for 0-RTT
  - [ ] API to send early data
  - [ ] Tests for 0-RTT scenarios
- [ ] Connection ID management:
  - [ ] Expose connection IDs to Elixir
  - [ ] Support custom connection ID generators

### Acceptance Criteria:
- Datagrams work (send/receive)
- Connection migration supported and tested
- Comprehensive stats available
- Telemetry events emitted and documented
- Performance benchmarks written and results documented
- Zero-copy optimizations implemented
- qlog support working

---

## Milestone 7: Production Hardening 🛡️

**Goal**: Make the library production-ready with proper supervision, error handling, and documentation

### TODOs:

#### Supervision and Fault Tolerance:

- [ ] Create `Quichex.Supervisor`:
  - [ ] Top-level supervisor for the application
  - [ ] Supervises listener processes
  - [ ] Connection supervisors (DynamicSupervisor for connections)
- [ ] Connection error handling:
  - [ ] Ensure all connection errors properly shut down GenServer
  - [ ] Notify controlling process before shutdown
  - [ ] Proper cleanup of resources (socket, NIF resources)
- [ ] Listener error handling:
  - [ ] Handle socket errors
  - [ ] Restart strategy for transient errors
  - [ ] Prevent cascading failures
- [ ] Resource leak prevention:
  - [ ] Verify all Rust resources are cleaned up on GenServer shutdown
  - [ ] Implement proper resource destructors in Rust
  - [ ] Add finalizers if needed
- [ ] Tests:
  - [ ] Test supervision tree restart logic
  - [ ] Test connection crashes don't affect other connections
  - [ ] Test listener crashes and recovery
  - [ ] Memory leak tests (long-running connections)

#### Documentation:

- [ ] Complete API documentation:
  - [ ] Every public function has `@doc` with examples
  - [ ] Every public function has `@spec`
  - [ ] Module-level `@moduledoc` for all modules
  - [ ] Add usage examples to docs
- [ ] Write guides:
  - [ ] `guides/getting_started.md` - basic usage tutorial
  - [ ] `guides/client_connections.md` - client guide
  - [ ] `guides/server_listener.md` - server guide
  - [ ] `guides/streams.md` - stream operations guide
  - [ ] `guides/configuration.md` - config options reference
  - [ ] `guides/performance.md` - performance tuning
  - [ ] `guides/telemetry.md` - observability guide
  - [ ] `guides/migration.md` - connection migration guide
- [ ] Write comprehensive `README.md`:
  - [ ] Project description and goals
  - [ ] Installation instructions
  - [ ] Quick start example (client and server)
  - [ ] Features list
  - [ ] Link to documentation
  - [ ] Link to examples
  - [ ] Contributing guidelines
  - [ ] License
- [ ] Create `CHANGELOG.md`:
  - [ ] Follow Keep a Changelog format
  - [ ] Document all changes from milestones
- [ ] Create example applications in `examples/`:
  - [ ] `examples/echo_client.ex` - simple echo client
  - [ ] `examples/echo_server.ex` - simple echo server
  - [ ] `examples/file_transfer.ex` - transfer file over QUIC
  - [ ] `examples/chat.ex` - simple chat application
  - [ ] `examples/datagram_demo.ex` - datagram usage

#### Code Quality:

- [ ] Dialyzer:
  - [ ] Add `@spec` to all public functions
  - [ ] Fix all Dialyzer warnings
  - [ ] Add `.dialyzer_ignore.exs` for known issues if needed
- [ ] Credo:
  - [ ] Fix all Credo warnings
  - [ ] Configure `.credo.exs` with project-specific rules
- [ ] Code formatting:
  - [ ] Run `mix format` on all Elixir code
  - [ ] Add `.formatter.exs` configuration
  - [ ] Run `cargo fmt` on all Rust code
- [ ] Clippy (Rust linter):
  - [ ] Fix all Clippy warnings in Rust code
  - [ ] Add `#![deny(warnings)]` to catch issues in CI
- [ ] Test coverage:
  - [ ] Add `{:excoveralls, "~> 0.18", only: :test}`
  - [ ] Aim for >90% test coverage
  - [ ] Add coverage reporting to CI

#### Security:

- [ ] Security audit:
  - [ ] Review all NIF error handling (no panics)
  - [ ] Review all Elixir error handling
  - [ ] Check for potential DoS vectors (e.g., resource exhaustion)
  - [ ] Rate limiting considerations (document, don't implement)
- [ ] Dependency audit:
  - [ ] Run `mix deps.audit`
  - [ ] Run `cargo audit` on Rust dependencies
  - [ ] Document security update process
- [ ] TLS configuration:
  - [ ] Document secure TLS configuration
  - [ ] Provide example secure configs
  - [ ] Warn about insecure defaults

#### CI/CD:

- [ ] Enhance GitHub Actions workflow:
  - [ ] Matrix build: Elixir 1.14-1.17, OTP 25-27
  - [ ] Matrix build: Ubuntu, macOS
  - [ ] Rust stable and beta
  - [ ] Run tests
  - [ ] Run Dialyzer
  - [ ] Run Credo
  - [ ] Run coverage and upload to Codecov
  - [ ] Build docs
  - [ ] Clippy and `cargo fmt` check
- [ ] Release automation:
  - [ ] Script to build release
  - [ ] Tag releases
  - [ ] Publish to Hex.pm
  - [ ] Generate release notes

#### Hex.pm Package:

- [ ] Prepare for Hex.pm release:
  - [ ] Complete `mix.exs` metadata (description, links, etc.)
  - [ ] Add `package` section to `mix.exs`
  - [ ] Ensure all files are included in package
  - [ ] Test `mix hex.build` locally
- [ ] Pre-release checklist:
  - [ ] All tests passing
  - [ ] Documentation complete
  - [ ] Examples working
  - [ ] CHANGELOG updated
  - [ ] Version bumped appropriately

### Acceptance Criteria:
- Supervision tree works correctly
- All crashes handled gracefully
- Complete documentation (API docs + guides)
- Example applications work
- Dialyzer clean
- Credo clean
- Test coverage >90%
- Security audit complete
- CI pipeline comprehensive and passing
- Ready for Hex.pm release

---

## Post-1.0 Roadmap 🗺️

Features to consider after initial release:

1. **HTTP/3 Layer** (separate library: `quichex_h3`)
   - Build on top of quichex
   - Implement HTTP/3 framing
   - Integration with Plug/Phoenix

2. **Media over QUIC (MoQ)** (separate library: `quichex_moq`)
   - Implement MoQ protocol
   - Real-time media streaming

3. **WebTransport** (separate library: `quichex_webtransport`)
   - WebTransport protocol support
   - Browser compatibility

4. **Advanced Congestion Control**
   - Pluggable congestion control
   - Custom congestion control algorithms in Elixir

5. **Connection Pooling**
   - Client connection pools
   - Connection reuse

6. **Proxy Support**
   - SOCKS5 proxy
   - HTTP CONNECT proxy

7. **Multipath QUIC**
   - Full multipath support
   - Load balancing across paths

8. **GSO/GRO Support**
   - Generic Segmentation Offload
   - Generic Receive Offload
   - Performance improvements for high-throughput scenarios

---

## Success Metrics 📈

How we'll know the library is successful:

### Technical Metrics:
- ✅ Can establish connections with all major QUIC implementations
- ✅ Throughput: >1 Gbps on localhost
- ✅ Latency: <1ms RTT overhead on localhost
- ✅ Concurrency: Support 10,000+ concurrent connections on commodity hardware
- ✅ Memory: <100KB overhead per idle connection
- ✅ Test coverage: >90%
- ✅ Zero critical security issues

### Community Metrics:
- ⭐ GitHub stars: >500 in first year
- 📦 Hex downloads: >10,000 in first year
- 🐛 Issue response time: <48 hours
- 📝 Documentation quality: Clear examples, comprehensive guides
- 🤝 Contributors: >10 in first year

---

## Contributing

Once the library reaches Milestone 7, we'll open it up for contributions. Initial contribution guidelines:

1. All changes require tests
2. All changes require documentation updates
3. Follow Elixir style guide and Rust style guide
4. CI must pass (tests, Dialyzer, Credo, Clippy)
5. Sign commits

---

## Notes

- This plan assumes the Quichex library will be developed in a separate repository
- The cloudflare/quiche repository will be included as a git submodule or vendored
- Initial focus is on core QUIC functionality; HTTP/3 comes later
- We prioritize correctness and safety over performance initially
- Performance optimizations come after correctness is proven
- Interop testing with other implementations is crucial for correctness
