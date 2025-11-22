# Quichex Implementation Plan

**An Elixir library providing QUIC transport via Rustler bindings to cloudflare/quiche**

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
│  - Quichex.Connection (GenServer)                       │
│  - Quichex.Listener (GenServer)                         │
│  - Quichex.Config (struct + builder)                    │
│  - Quichex.Stream (abstraction)                         │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ Quichex.NIF (Rustler NIFs - Internal)                   │
│  - config_* functions                                   │
│  - connection_* functions                               │
│  - Resource management                                  │
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
│  - UDP socket I/O                                       │
└─────────────────────────────────────────────────────────┘
```

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
# Start a client connection
{:ok, conn_pid} = Quichex.Connection.connect(
  host: "cloudflare-quic.com",
  port: 443,
  config: config,
  # Optional:
  local_port: 0,  # random port
  active: true    # like :gen_tcp/:gen_udp active mode
)

# Wait for handshake completion
case Quichex.Connection.wait_connected(conn_pid, timeout: 5000) do
  :ok -> IO.puts("Connected!")
  {:error, reason} -> IO.puts("Failed: #{inspect(reason)}")
end

# Alternative: async notifications
receive do
  {:quic_connected, ^conn_pid} ->
    IO.puts("Connection established")
  {:quic_connection_error, ^conn_pid, reason} ->
    IO.puts("Connection failed: #{inspect(reason)}")
end

# Get connection stats
{:ok, stats} = Quichex.Connection.stats(conn_pid)
# => %{
#   rtt: 45_000,  # microseconds
#   cwnd: 14_000, # bytes
#   bytes_sent: 1_234_567,
#   bytes_received: 987_654,
#   ...
# }
```

### Stream Operations

```elixir
# Open a stream
{:ok, stream_id} = Quichex.Connection.open_stream(conn_pid, :bidirectional)
# or
{:ok, stream_id} = Quichex.Connection.open_stream(conn_pid, :unidirectional)

# Send data on stream
:ok = Quichex.Connection.stream_send(conn_pid, stream_id, "Hello", fin: false)
:ok = Quichex.Connection.stream_send(conn_pid, stream_id, " QUIC!", fin: true)

# Active mode (default): receive messages
receive do
  {:quic_stream, ^conn_pid, ^stream_id, data} ->
    IO.puts("Received: #{data}")

  {:quic_stream_fin, ^conn_pid, ^stream_id} ->
    IO.puts("Stream finished")

  {:quic_stream_reset, ^conn_pid, ^stream_id, error_code} ->
    IO.puts("Stream reset: #{error_code}")
end

# Passive mode: explicit receive
{:ok, data, fin?} = Quichex.Connection.stream_recv(conn_pid, stream_id)

# Get readable/writable streams
{:ok, readable_streams} = Quichex.Connection.readable_streams(conn_pid)
{:ok, writable_streams} = Quichex.Connection.writable_streams(conn_pid)

# Close/reset stream
:ok = Quichex.Connection.stream_shutdown(conn_pid, stream_id, :read, error_code: 0)
:ok = Quichex.Connection.stream_shutdown(conn_pid, stream_id, :write, error_code: 0)
:ok = Quichex.Connection.stream_shutdown(conn_pid, stream_id, :both, error_code: 0)
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

## Message Protocol

When `active: true` (default), the connection sends messages to the controlling process:

```elixir
# Connection lifecycle
{:quic_connected, conn_pid}
{:quic_connection_error, conn_pid, reason}
{:quic_connection_closed, conn_pid, error_code, reason}

# Streams
{:quic_stream, conn_pid, stream_id, data}
{:quic_stream_fin, conn_pid, stream_id}
{:quic_stream_reset, conn_pid, stream_id, error_code}
{:quic_stream_stopped, conn_pid, stream_id, error_code}

# Datagrams
{:quic_dgram, conn_pid, data}

# Path events (for migration)
{:quic_path_created, conn_pid, path_id, local_addr, peer_addr}
{:quic_path_validated, conn_pid, path_id}
{:quic_path_failed, conn_pid, path_id, reason}
```

## Validation Strategy

### 1. Unit Tests
- Test each NIF function in isolation with `ExUnit`
- Property-based testing with `StreamData` for stream operations
- Edge cases: invalid inputs, buffer boundaries, connection states

### 2. Integration Tests
- Full client-server flow within same VM
- Multiple concurrent connections
- Stream multiplexing
- Connection migration scenarios
- Timeout and error handling

### 3. Interoperability Tests
- Connect to `quiche-server` (from this repo)
- Connect to other QUIC implementations (msquic, quinn, etc.)
- Test against public QUIC servers (cloudflare-quic.com, etc.)
- Server mode: accept connections from standard QUIC clients

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

- [ ] Create new Mix project: `mix new quichex --sup`
- [ ] Add dependencies to `mix.exs`:
  - [ ] `{:rustler, "~> 0.35"}`
  - [ ] `{:ex_doc, "~> 0.34", only: :dev}`
  - [ ] `{:dialyxir, "~> 1.4", only: :dev, runtime: false}`
  - [ ] `{:credo, "~> 1.7", only: :dev, runtime: false}`
- [ ] Run `mix rustler.new` to create NIF boilerplate
- [ ] Configure `native/quichex_nif/Cargo.toml`:
  - [ ] Add dependency on quiche from local path: `quiche = { path = "../../../quiche", features = ["boringssl-boring-crate"] }`
  - [ ] Add dependency: `rustler = "0.35"`
  - [ ] Add dependency: `lazy_static = "1.5"` (for resource registration)
- [ ] Create basic module structure:
  - [ ] `lib/quichex.ex` - Main module with version info
  - [ ] `lib/quichex/nif.ex` - NIF loading and stubs
  - [ ] `lib/quichex/config.ex` - Config struct and builder
  - [ ] `lib/quichex/connection.ex` - Connection GenServer (stub)
- [ ] Implement basic "hello world" NIF to verify Rustler works
- [ ] Set up GitHub Actions CI:
  - [ ] Rust stable compilation
  - [ ] Mix tests
  - [ ] Mix format check
  - [ ] Credo
  - [ ] Dialyzer
- [ ] Write `README.md` with project overview
- [ ] Set up `mix docs` with examples
- [ ] Add `LICENSE` file (same as quiche: BSD-2-Clause)

### Acceptance Criteria:
- `mix compile` succeeds and builds Rust NIF
- `mix test` runs (even with empty tests)
- Basic NIF function can be called from Elixir
- CI pipeline passes

---

## Milestone 2: Config and Core NIFs 🔧

**Goal**: Implement configuration builder and core connection resource management

### TODOs:

#### Rust Side (native/quichex_nif/src/):

- [ ] Create `lib.rs` with NIF initialization:
  - [ ] `rustler::init!` macro with all exported functions
  - [ ] Load BoringSSL properly for quiche
- [ ] Create `resources.rs`:
  - [ ] `ConfigResource` struct wrapping `Arc<Mutex<quiche::Config>>`
  - [ ] `ConnectionResource` struct wrapping `Arc<Mutex<quiche::Connection>>`
  - [ ] Implement `rustler::Resource` for both
  - [ ] Resource registration in `on_load` callback
- [ ] Create `config.rs` with Config NIFs:
  - [ ] `config_new(version: u32) -> Result<ResourceArc<ConfigResource>, String>`
  - [ ] `config_set_application_protos(config, protos: Vec<String>) -> Result<(), String>`
  - [ ] `config_set_max_idle_timeout(config, millis: u64) -> Result<(), String>`
  - [ ] `config_set_initial_max_streams_bidi(config, v: u64) -> Result<(), String>`
  - [ ] `config_set_initial_max_streams_uni(config, v: u64) -> Result<(), String>`
  - [ ] `config_set_initial_max_data(config, v: u64) -> Result<(), String>`
  - [ ] `config_set_initial_max_stream_data_bidi_local(config, v: u64) -> Result<(), String>`
  - [ ] `config_set_initial_max_stream_data_bidi_remote(config, v: u64) -> Result<(), String>`
  - [ ] `config_set_initial_max_stream_data_uni(config, v: u64) -> Result<(), String>`
  - [ ] `config_verify_peer(config, verify: bool) -> Result<(), String>`
  - [ ] `config_load_cert_chain_from_pem_file(config, path: String) -> Result<(), String>`
  - [ ] `config_load_priv_key_from_pem_file(config, path: String) -> Result<(), String>`
  - [ ] `config_load_verify_locations_from_file(config, path: String) -> Result<(), String>`
  - [ ] `config_set_cc_algorithm(config, algo: String) -> Result<(), String>`
  - [ ] `config_enable_dgram(config, enabled: bool, recv_queue: usize, send_queue: usize) -> Result<(), String>`
- [ ] Create `types.rs` for shared type conversions:
  - [ ] Elixir term <-> `SocketAddr` conversion
  - [ ] Elixir term <-> `quiche::RecvInfo` conversion
  - [ ] Elixir term <-> `quiche::SendInfo` conversion
  - [ ] Error enum -> Elixir error atom mapping

#### Elixir Side:

- [ ] Implement `Quichex.NIF` module:
  - [ ] `use Rustler` with proper otp_app and crate settings
  - [ ] Stub functions for all NIFs that raise `NifNotLoadedError`
  - [ ] Proper `@spec` annotations for all NIFs
- [ ] Implement `Quichex.Config`:
  - [ ] Define `%Quichex.Config{}` struct holding `ConfigResource`
  - [ ] `new(opts \\ []) :: t()` - creates config with defaults
  - [ ] Pipeline functions: `set_application_protos/2`, `set_max_idle_timeout/2`, etc.
  - [ ] Validate inputs (positive numbers, valid file paths, etc.)
  - [ ] `@doc` for every public function
  - [ ] `@spec` type annotations
- [ ] Create `Quichex.Error` module:
  - [ ] Define error types as atoms: `:invalid_config`, `:connection_error`, etc.
  - [ ] `message/1` function to get human-readable error messages
- [ ] Write comprehensive tests:
  - [ ] `test/quichex/config_test.exs` - test all config builder functions
  - [ ] Test invalid inputs return proper errors
  - [ ] Test config resource is created and can be reused

### Acceptance Criteria:
- Config can be created and configured from Elixir
- All config setter NIFs work correctly
- Config resource properly managed (no memory leaks)
- 100% test coverage for Config module
- Documentation complete with examples

---

## Milestone 3: Client Connection Establishment 🔌

**Goal**: Successfully establish a QUIC client connection and complete handshake

### TODOs:

#### Rust Side:

- [ ] Create `connection.rs` with connection NIFs:
  - [ ] `connection_new_client(scid: Vec<u8>, server_name: Option<String>, local_addr: String, peer_addr: String, config: ResourceArc<ConfigResource>) -> Result<ResourceArc<ConnectionResource>, String>`
  - [ ] `connection_recv(conn: ResourceArc<ConnectionResource>, packet: Binary, recv_info: RecvInfoTerm) -> Result<usize, String>`
  - [ ] `connection_send(conn: ResourceArc<ConnectionResource>) -> Result<(OwnedBinary, SendInfoTerm), String>`
  - [ ] `connection_timeout(conn: ResourceArc<ConnectionResource>) -> Result<Option<u64>, String>` (returns millis)
  - [ ] `connection_on_timeout(conn: ResourceArc<ConnectionResource>) -> Result<(), String>`
  - [ ] `connection_is_established(conn: ResourceArc<ConnectionResource>) -> Result<bool, String>`
  - [ ] `connection_is_closed(conn: ResourceArc<ConnectionResource>) -> Result<bool, String>`
  - [ ] `connection_close(conn: ResourceArc<ConnectionResource>, app: bool, err: u64, reason: Vec<u8>) -> Result<(), String>`
- [ ] Handle errors properly:
  - [ ] Map `quiche::Error` to descriptive error tuples/strings
  - [ ] Special handling for `Error::Done` (not really an error)

#### Elixir Side:

- [ ] Implement `Quichex.Connection` GenServer:
  - [ ] `start_link/1` - accepts config, host, port, opts
  - [ ] `init/1` - opens UDP socket, creates connection resource, sends initial packets
  - [ ] `handle_info({:udp, ...})` - processes incoming packets
  - [ ] `handle_info(:timeout, ...)` - handles QUIC timeout events
  - [ ] Private `send_pending_packets/1` - drains packets from quiche and sends via UDP
  - [ ] Private `schedule_next_timeout/1` - schedules next timeout based on `connection_timeout`
  - [ ] Private `notify_controlling_process/2` - sends messages based on active mode
  - [ ] Connection ID generation (random 16 bytes)
- [ ] Implement client API:
  - [ ] `connect/1` - starts connection GenServer as client
  - [ ] `wait_connected/2` - blocks until handshake completes or timeout
  - [ ] `close/2` - gracefully closes connection
  - [ ] `is_established?/1` - checks if handshake done
- [ ] State management:
  - [ ] Track: socket, conn_resource, peer_address, controlling_process, active mode
  - [ ] Track: handshake completion, connection closure
  - [ ] Handle state transitions properly
- [ ] Error handling:
  - [ ] Connection errors -> notify controlling process and stop GenServer
  - [ ] Socket errors -> proper cleanup
  - [ ] Timeout errors -> attempt graceful close

#### Tests:

- [ ] Create `test/quichex/connection_test.exs`:
  - [ ] Test connecting to `cloudflare-quic.com:443` (integration test)
  - [ ] Test connection timeout handling
  - [ ] Test invalid server name/address errors
  - [ ] Test graceful close
  - [ ] Test connection establishment messages in active mode
- [ ] Create helper: `test/support/quic_test_helpers.ex`:
  - [ ] Generate test configs
  - [ ] Generate random connection IDs
  - [ ] Test utilities

### Acceptance Criteria:
- Can successfully connect to cloudflare-quic.com and complete handshake
- Connection properly handles timeouts during handshake
- Controlling process receives `:quic_connected` message
- Connection can be gracefully closed
- All error paths tested
- No memory leaks in connection lifecycle

---

## Milestone 4: Stream Operations 📊

**Goal**: Send and receive data on QUIC streams with proper flow control

### TODOs:

#### Rust Side:

- [ ] Add stream NIFs to `connection.rs`:
  - [ ] `connection_stream_send(conn: ResourceArc<ConnectionResource>, stream_id: u64, data: Binary, fin: bool) -> Result<usize, String>`
  - [ ] `connection_stream_recv(conn: ResourceArc<ConnectionResource>, stream_id: u64, max_len: usize) -> Result<(OwnedBinary, bool), String>`
  - [ ] `connection_readable_streams(conn: ResourceArc<ConnectionResource>) -> Result<Vec<u64>, String>`
  - [ ] `connection_writable_streams(conn: ResourceArc<ConnectionResource>) -> Result<Vec<u64>, String>`
  - [ ] `connection_stream_finished(conn: ResourceArc<ConnectionResource>, stream_id: u64) -> Result<bool, String>`
  - [ ] `connection_stream_shutdown(conn: ResourceArc<ConnectionResource>, stream_id: u64, direction: String, err_code: u64) -> Result<(), String>`
- [ ] Optimize for zero-copy where possible:
  - [ ] Use `Binary` for receives (avoid copying)
  - [ ] Consider using `OwnedBinary` efficiently

#### Elixir Side:

- [ ] Extend `Quichex.Connection` with stream support:
  - [ ] `open_stream/2` - opens bidirectional or unidirectional stream
  - [ ] `stream_send/4` - sends data on stream (with `fin` option)
  - [ ] `stream_recv/3` - passive mode receive
  - [ ] `stream_shutdown/3` - shutdown stream read/write/both
  - [ ] `readable_streams/1` - get list of readable streams
  - [ ] `writable_streams/1` - get list of writable streams
- [ ] Enhance `handle_info({:udp, ...})` to:
  - [ ] Check for readable streams after processing packets
  - [ ] Read data from readable streams
  - [ ] Send `:quic_stream` messages to controlling process (active mode)
  - [ ] Detect stream FIN and send `:quic_stream_fin` message
  - [ ] Handle stream errors/resets
- [ ] Add GenServer call handlers for stream operations:
  - [ ] `{:stream_send, stream_id, data, fin}` -> send data and flush packets
  - [ ] `{:stream_recv, stream_id}` -> passive read
  - [ ] `{:stream_shutdown, stream_id, direction, error_code}`
  - [ ] `{:open_stream, type}` -> allocate and return stream ID
- [ ] Stream state tracking:
  - [ ] Track opened streams (Map: stream_id -> state)
  - [ ] Track stream direction (bidi vs uni)
  - [ ] Track FIN sent/received
  - [ ] Clean up closed streams
- [ ] Flow control awareness:
  - [ ] Handle `Error::StreamLimit` when opening streams
  - [ ] Handle `Error::FlowControl` and backpressure
  - [ ] Respect writable streams to avoid blocking sends

#### Tests:

- [ ] Create `test/quichex/stream_test.exs`:
  - [ ] Test opening bidirectional and unidirectional streams
  - [ ] Test sending and receiving data on streams
  - [ ] Test stream multiplexing (multiple concurrent streams)
  - [ ] Test FIN handling (send and receive)
  - [ ] Test stream shutdown
  - [ ] Test stream errors and resets
  - [ ] Test flow control limits
  - [ ] Property-based test: send random data, verify received correctly
- [ ] Integration test: client-server stream communication
  - [ ] Start local test server
  - [ ] Connect client
  - [ ] Open multiple streams
  - [ ] Send data bidirectionally
  - [ ] Verify all data received correctly

### Acceptance Criteria:
- Can open streams (both bidi and uni)
- Can send data on streams with proper flow control
- Can receive data on streams in active mode
- Multiple streams work concurrently without interference
- FIN handling works correctly
- Stream lifecycle messages delivered to controlling process
- No data corruption or loss in streams
- Property-based tests pass (random data verified)

---

## Milestone 5: Server-Side Listener 🖥️

**Goal**: Accept incoming QUIC connections as a server

### TODOs:

#### Rust Side:

- [ ] Add server NIFs to `connection.rs`:
  - [ ] `connection_new_server(scid: Vec<u8>, odcid: Option<Vec<u8>>, local_addr: String, peer_addr: String, config: ResourceArc<ConfigResource>) -> Result<ResourceArc<ConnectionResource>, String>`
  - [ ] `header_info(packet: Binary, scid_len: usize) -> Result<HeaderInfoTerm, String>` - parse packet header without full decode
  - [ ] `retry(scid: Vec<u8>, dcid: Vec<u8>, new_scid: Vec<u8>, token: Vec<u8>, version: u32) -> Result<OwnedBinary, String>` - generate retry packet
  - [ ] `negotiate_version(scid: Vec<u8>, dcid: Vec<u8>) -> Result<OwnedBinary, String>`
- [ ] Add connection ID generation helpers:
  - [ ] Simple random SCID generator (can be called from Elixir)

#### Elixir Side:

- [ ] Create `Quichex.Listener` GenServer:
  - [ ] `start_link/1` - starts listener on specified port with config
  - [ ] `init/1` - opens UDP socket in active mode
  - [ ] `handle_info({:udp, ...})` - receives packets and dispatches to connections
  - [ ] Connection routing table (Map: connection_id -> connection_pid)
  - [ ] Handle new connections:
    - [ ] Parse header to get DCID
    - [ ] If DCID unknown, create new connection (call `accept_new_connection/3`)
    - [ ] If DCID known, route packet to existing connection
  - [ ] `accept_new_connection/3` - creates new Connection GenServer
  - [ ] `register_connection/3` - adds connection to routing table
  - [ ] `unregister_connection/2` - removes from routing table when closed
  - [ ] Support for address validation (stateless retry):
    - [ ] Optional: generate and verify retry tokens
    - [ ] Config option to enable/disable retry
- [ ] Enhance `Quichex.Connection`:
  - [ ] Support server-side initialization (different from client)
  - [ ] Handle `is_server: true` mode
  - [ ] Connection resource created via `connection_new_server`
  - [ ] Different initial state (wait for client Initial packet)
- [ ] Create `Quichex.ConnectionHandler` behaviour:
  - [ ] `@callback handle_connection(conn :: pid(), peer :: address()) :: :ok | {:error, term()}`
  - [ ] Allow users to provide custom connection handlers
- [ ] Listener API:
  - [ ] `start_link/1` with options: port, config, connection_handler, active mode
  - [ ] `stop/1` - gracefully stop listener
  - [ ] `connections/1` - list active connections

#### Tests:

- [ ] Create `test/quichex/listener_test.exs`:
  - [ ] Test starting listener on specific port
  - [ ] Test accepting connections from test client
  - [ ] Test multiple concurrent connections
  - [ ] Test connection routing (packets go to correct connection)
  - [ ] Test listener shutdown
  - [ ] Test connection handler callback
  - [ ] Test active mode (messages sent to parent process)
- [ ] Interop test: `quiche-client` connecting to Quichex listener
  - [ ] Start Quichex listener
  - [ ] Use `System.cmd` to run `cargo run --bin quiche-client`
  - [ ] Verify connection succeeds
  - [ ] Exchange data on streams

### Acceptance Criteria:
- Listener can be started on any available port
- Listener accepts connections from standard QUIC clients
- Multiple concurrent connections handled correctly
- Connection routing works (packets reach correct connection)
- Can verify interop with `quiche-client` from this repo
- Connection handler behaviour works
- Clean shutdown of listener and all connections

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

- [ ] Rust NIFs:
  - [ ] `connection_stats(conn) -> Result<StatsMap, String>` - comprehensive stats
  - [ ] Include: RTT, cwnd, bytes sent/received, packets lost, etc.
- [ ] Elixir API:
  - [ ] `stats/1` - get connection statistics
  - [ ] `path_stats/2` - get per-path statistics
- [ ] Telemetry integration:
  - [ ] Add dependency: `{:telemetry, "~> 1.0"}`
  - [ ] Emit telemetry events for:
    - [ ] Connection established
    - [ ] Connection closed
    - [ ] Stream opened/closed
    - [ ] Bytes sent/received
    - [ ] Packets lost
  - [ ] Document all telemetry events
- [ ] Tests:
  - [ ] Verify stats are accurate
  - [ ] Verify telemetry events are emitted

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
