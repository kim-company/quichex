# Testing Guide

This guide covers testing both client and server implementations in Quichex.

## Test Categories

| Category | Count | Server Required | Run Time | Command |
|----------|-------|-----------------|----------|---------|
| **Unit Tests** | 58 | No | ~1.8s (0.2s async, 1.6s sync) | `mix test --exclude external` |
| **Integration Tests** | 7 | Internal | ~1.7s (async: false) | `mix test test/quichex/listener_integration_test.exs` |
| **External Tests** | 15 | cloudflare-quic.com | ~1-2s | `mix test --only external` |

**Total: 73 tests, all passing ✅**

### Quick Test Commands

**Run all tests except external**:
```bash
mix test
```

**Run only unit tests** (no server, no internet needed):
```bash
mix test --exclude external --exclude integration
```

**Run integration tests** (internal client-server):
```bash
mix test test/quichex/listener_integration_test.exs
```

**Run all tests including external servers** (requires internet):
```bash
mix test --include external
```

---

## Test Architecture

Quichex tests are organized into distinct layers based on what they're testing:

### Unit Tests (Direct Connection API)

**Layer**: `Connection.start_link/1` via `start_link_supervised!/1`

Unit tests bypass the ConnectionRegistry pool to test Connection functionality in isolation. They use:
- **Direct API**: `start_link_supervised!({Connection, opts})`
- **Test Handler**: `Quichex.Test.NoOpHandler` (no message notifications)
- **ExUnit Supervisor**: Automatic cleanup, no manual process management
- **Async**: Tests run in parallel (`async: true`)

**Benefits**:
- Fast execution (minimal overhead)
- Perfect isolation (each test gets its own supervision tree)
- Clean output (no handler messages to ExUnit supervisor)
- No shared state between tests

**Example**:
```elixir
test "creates a connection with valid config" do
  config = Config.new!()
  pid = start_link_supervised!({Connection, [
    host: "127.0.0.1",
    port: 9999,
    config: config,
    handler: NoOpHandler
  ]})
  assert Process.alive?(pid)
  # No cleanup needed - ExUnit supervisor handles it
end
```

### Integration Tests (Full Supervision Path)

**Layer**: `Quichex.start_connection/1` via ConnectionRegistry

Integration tests use the full production supervision tree:
- **Public API**: `Quichex.start_connection/1`
- **Supervision**: Via ConnectionRegistry pool (bounded worker slots)
- **Default Handler**: `Quichex.Handler.Default` (sends messages)
- **Async**: False for listener tests (shared ConnectionRegistry pool)

**Benefits**:
- Tests real supervision behavior
- Validates full application path
- Tests handler message protocol
- Realistic concurrency patterns

**Example**:
```elixir
test "echo test" do
  {:ok, client} = ListenerHelpers.start_client(port,
    handler_opts: [controlling_process: self()]
  )
  # Uses full supervision via ConnectionRegistry pool
  assert_receive {:quic_connected, ^client}
end
```

### Test Handlers

**NoOpHandler** (`test/support/noop_handler.ex`):
- For unit tests that don't need notifications
- Implements all `Quichex.Handler` callbacks as no-ops
- Prevents error logs from unhandled messages

**EchoHandler** (`test/support/echo_handler.ex`):
- For integration tests with server
- Echoes stream data back to client
- Tests full bidirectional communication

---

## Test Certificates

Self-signed certificates for testing are located in `priv/`:
- `priv/cert.crt` - Certificate file (valid for 1 year)
- `priv/cert.key` - Private key file
- Subject: CN=localhost, O=Quichex Test, C=US

Generated with:
```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout priv/cert.key \
  -out priv/cert.crt \
  -days 365 \
  -subj "/CN=localhost/O=Quichex Test/C=US"
```

To regenerate (when expired):
```bash
cd priv
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout cert.key \
  -out cert.crt \
  -days 365 \
  -subj "/CN=localhost/O=Quichex Test/C=US"
```

---

## Server-Side Testing (Quichex Listener)

### Echo Test

The primary integration test uses Quichex's own server implementation:

**Run the echo test**:
```bash
mix test test/quichex/listener_integration_test.exs:8
```

**What it tests**:
1. Start Quichex Listener on random port
2. Connect Quichex client to listener
3. Complete TLS handshake
4. Open stream and send data: "Hello, QUIC!"
5. Server echoes data back
6. Verify received data matches

**Status**: ✅ Passing consistently (100% stability over 5+ runs, ~80ms each)

### Test Infrastructure

**EchoHandler** (`test/support/echo_handler.ex`):
- Server-side handler that echoes stream data back to client
- Implements `Quichex.Handler` behaviour
- Auto-reads streams when readable
- Sends data back with same FIN flag

**ListenerHelpers** (`test/support/listener_helpers.ex`):
- Helper functions for starting listeners and clients
- Certificate loading from priv/
- Configuration builders for server and client
- Wait helpers for connection establishment

**Example Usage**:
```elixir
# Start listener with EchoHandler
listener_spec = ListenerHelpers.listener_spec(
  handler: EchoHandler,
  handler_opts: []
)
listener = start_link_supervised!(listener_spec)

# Get listener port
{:ok, {_ip, port}} = Listener.local_address(listener)

# Connect client
{:ok, client} = ListenerHelpers.start_client(port,
  handler_opts: [controlling_process: self()]
)

# Wait for connection
:ok = ListenerHelpers.wait_for_connection(client, 1_000)

# Open stream and send data
{:ok, stream_id} = Connection.open_stream(client, type: :bidirectional)
{:ok, _bytes} = Connection.stream_send(client, stream_id, "Hello, QUIC!", fin: true)

# Receive echo
{:ok, data, true} = ListenerHelpers.wait_for_stream_data(client, stream_id, 2_000)
assert data == "Hello, QUIC!"
```

### Integration Test Suite

Location: `test/quichex/listener_integration_test.exs`

**All 7 tests passing ✅**:
1. ✅ Echo test - client sends data, server echoes back
2. ✅ Listener tracks active connections
3. ✅ Multiple streams on single connection
4. ✅ Multiple concurrent connections (10 clients)
5. ✅ Listener shutdown with active connections
6. ✅ Connection close from client side
7. ✅ Large data transfer (100KB bidirectional)

**Test Configuration**:
- `async: false` - Tests share global ConnectionRegistry pool
- Uses full supervision path via `Quichex.start_connection/1`
- EchoHandler for server-side message handling
- Clean output: No error logs

### Running Specific Tests

**Run single test**:
```bash
mix test test/quichex/listener_integration_test.exs:8
```

**Run with trace** (see test names):
```bash
mix test test/quichex/listener_integration_test.exs --trace
```

**Run all integration tests**:
```bash
mix test test/quichex/listener_integration_test.exs
```

---

## Client-Side Testing (cloudflare-quic.com)

### External Integration Tests

Tests against public QUIC servers (requires internet):

**Run external tests**:
```bash
mix test --include external
```

**What's tested**:
- Connection to cloudflare-quic.com:443
- TLS handshake with real certificate
- Stream operations over internet
- ALPN negotiation ("h3" protocol)

**Location**: `test/quichex/connection_test.exs` (marked with `@tag :external`)

---

## Testing with quiche-server

For interop testing with cloudflare's reference implementation:

### Prerequisites

Build the quiche-server (one-time setup):
```bash
cd ../quiche
git submodule update --init --recursive
cargo build --examples
```

### Start quiche-server

**Basic server** (uses quiche's test certificates):
```bash
cd ../quiche/quiche
RUST_LOG=info ../../target/debug/examples/server
```

**With Quichex certificates**:
```bash
cd ../quiche
target/debug/examples/server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key \
  --listen 127.0.0.1:4433
```

### Debug Logging Levels

The server uses `env_logger`:

**Trace level** (packet details):
```bash
RUST_LOG=trace target/debug/examples/server
```

**Debug level** (connection details):
```bash
RUST_LOG=debug target/debug/examples/server
```

**Info level** (general information):
```bash
RUST_LOG=info target/debug/examples/server
```

### Test Quichex Client Against quiche-server

```elixir
# In iex -S mix
config = Quichex.Config.new!()
  |> Quichex.Config.set_application_protos(["hq-interop"])
  |> Quichex.Config.verify_peer(false)

{:ok, conn} = Quichex.Connection.start_link(
  host: "127.0.0.1",
  port: 4433,
  config: config
)

# Open stream and send data
{:ok, stream_id} = Quichex.Connection.open_stream(conn, type: :bidirectional)
{:ok, _} = Quichex.Connection.stream_send(conn, stream_id, "GET /\r\n", fin: true)

# Receive response
receive do
  {:quic_stream_data, ^conn, ^stream_id, data, _fin} ->
    IO.puts("Received: #{data}")
end
```

---

## Debugging Tips

### Server-Side Debugging

**Enable debug logging** in test_helper.exs:
```elixir
# Change from:
Logger.configure(level: :warning)

# To:
Logger.configure(level: :debug)
```

**Add IO.puts for immediate visibility**:
```elixir
IO.puts("Server accept: scid=#{Base.encode16(scid)}")
```

**Check routing table**:
```elixir
IO.puts("Routing packet: DCID=#{dcid_hex}, known_dcids=#{inspect(known_dcids_hex)}")
```

### Connection Issues

**Check connection state**:
```elixir
Quichex.Connection.is_established?(conn)  # Should be true after handshake
Quichex.Connection.is_closed?(conn)       # Should be false
```

**Check listener**:
```elixir
Quichex.Listener.connection_count(listener)  # Number of active connections
Quichex.Listener.local_address(listener)     # {ip, port}
```

### Common Issues

**Certificate Verification**:
- Use `verify_peer: false` for self-signed certs
- Ensure cert.crt hasn't expired (valid for 365 days)

**ALPN Mismatch**:
- Server and client must agree on protocol
- Use "hq-interop" for quiche-server
- Use "h3" for cloudflare-quic.com

**Port Already in Use**:
- Use port `0` to get random available port
- Check with `lsof -i :4433`

**Handshake Timeout**:
- Check firewall settings
- Verify server is running
- Check ALPN protocol matches

---

## Test Coverage

### Current Status (December 2025)

```
Unit Tests:
  Config Tests:                 40 tests ✅
  Connection Tests:             12 tests ✅
  Stream Tests:                  5 tests ✅
  Doctest:                       1 test  ✅

Integration Tests:
  Listener Integration:          7 tests ✅ (internal client-server)

External Tests:
  Connection (cloudflare):       1 test  ✅
  Integration (cloudflare):      4 tests ✅
  Stream (cloudflare):           8 tests ✅
  Listener (cloudflare):         2 tests ✅
─────────────────────────────────────────────────
Total:                          73 tests

Pass Rate:                      73/73 (100%) ✅
Stability:                      100% (verified over multiple runs)
Clean Output:                   No error logs ✅
```

**Test Quality Improvements**:
- ✅ Unit tests use `NoOpHandler` for clean output
- ✅ Integration tests properly use full supervision path
- ✅ All tests have proper cleanup (no resource leaks)
- ✅ External tests handle server-side connection closure gracefully
- ✅ Connections use `:temporary` restart strategy (correct OTP pattern)

### Running Full Suite

**Quick run** (unit + passing integration):
```bash
mix test
# ~1-2 seconds, 75+ passing
```

**With external tests**:
```bash
mix test --include external
# ~5-7 seconds, requires internet
```

---

## CI/CD Recommendations

**Fast CI** (unit tests only):
```bash
mix test --exclude external --exclude integration
# ~1 second, no dependencies
```

**Standard CI** (unit + internal integration):
```bash
mix test
# ~2 seconds, no external dependencies
```

**Full CI** (all tests):
```bash
mix test --include external
# ~5-7 seconds, requires internet for cloudflare-quic.com
```

---

## Next Steps

### Test Infrastructure (Complete ✅)

All core tests are passing with clean output. Test infrastructure improvements completed:
- ✅ Test layer architecture (unit vs integration)
- ✅ NoOpHandler for clean unit tests
- ✅ Proper supervision testing (temporary restart strategy)
- ✅ All 7 listener integration tests passing
- ✅ All 15 external cloudflare tests passing

### Future Testing

Advanced testing scenarios for Milestone 6+:
- Interop with quiche-client → Quichex server
- Stress testing (1000+ concurrent connections)
- Packet loss simulation
- Connection migration testing
- Performance benchmarks
- Datagram extension testing
- Path migration testing
