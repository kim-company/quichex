# Testing Guide

This guide covers testing the Quichex client implementation against the quiche-server.

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

## Running quiche-server

The quiche-server from cloudflare/quiche provides an excellent test server with detailed debug logging.

### Prerequisites

Build the debug version (preserves debug symbols for lldb):
```bash
cd ../quiche
cargo build --bin quiche-server
```

### Basic Usage

Minimal server with our test certificate:
```bash
cd ../quiche
target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key \
  --listen 127.0.0.1:4433
```

### Debug Logging Levels

The server uses `env_logger` and can be configured with the `RUST_LOG` environment variable:

**Trace level** (most verbose - packet details, buffer operations):
```bash
RUST_LOG=trace target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key
```

**Debug level** (connection details, socket options):
```bash
RUST_LOG=debug target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key
```

**Info level** (general information, connection stats):
```bash
RUST_LOG=info target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key
```

### Advanced Debug Features

**TLS Key Logging** (for Wireshark decryption):
```bash
RUST_LOG=debug SSLKEYLOGFILE=/tmp/sslkeys.log target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key
```

**QLOG Output** (structured QUIC event logging):
```bash
RUST_LOG=debug QLOGDIR=/tmp/qlogs target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key
```

**Packet Dumping** (save raw packets to files):
```bash
RUST_LOG=debug target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key \
  --dump-packets /tmp/packets
```

## Server Configuration Options

### Default Settings
- Listen address: `127.0.0.1:4433`
- HTTP version: `all` (HTTP/3 and HTTP/0.9)
- Max data: `10000000` bytes (10MB connection-wide)
- Max stream data: `1000000` bytes (1MB per stream)
- Max streams bidi: `100`
- Max streams uni: `100`
- Idle timeout: `30000` ms (30 seconds)
- Congestion control: `cubic`

### Useful Options for Testing

Disable stateless retry (simplifies handshake):
```bash
target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key \
  --no-retry
```

Adjust flow control limits:
```bash
target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key \
  --max-data 1000000 \
  --max-stream-data 100000
```

## Debug Information Available

When running with `RUST_LOG=debug` or `RUST_LOG=trace`, the server logs:

1. **Connection Establishment**
   - Source and destination connection IDs
   - Version negotiation
   - Stateless retry (if enabled)
   - Client address

2. **Packet Processing**
   - Packet size and direction
   - From/to addresses
   - Packet type (Initial, Handshake, 1-RTT)

3. **ALPN Negotiation**
   - Selected application protocol
   - HTTP/3 or HTTP/0.9

4. **Connection Statistics** (on close)
   - Bytes sent/received
   - Packets sent/received/lost
   - RTT statistics
   - Connection duration

5. **Path Events**
   - Connection migration
   - Path validation
   - New path detection

## Testing Quichex Client

### Basic Connection Test

1. Start the server:
```bash
cd ../quiche
RUST_LOG=debug target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key
```

2. In another terminal, test the Quichex client:
```elixir
# In iex -S mix
{:ok, conn} = Quichex.Connection.start_link(
  host: "127.0.0.1",
  port: 4433,
  verify_peer: false  # For self-signed cert
)
```

### Expected Server Output

On successful connection, you should see:
```
[DEBUG] New connection: dcid=<conn_id> scid=<conn_id>
[DEBUG] <trace_id> processed N bytes
[INFO] <trace_id> connection collected
```

## Wireshark Analysis

If you enabled `SSLKEYLOGFILE`, you can decrypt QUIC traffic in Wireshark:

1. Start Wireshark and capture on loopback (lo0)
2. Set the SSL/TLS key log file:
   - Preferences → Protocols → TLS → (Pre)-Master-Secret log filename
   - Point to your SSLKEYLOGFILE path
3. Filter: `udp.port == 4433`
4. Wireshark will decrypt QUIC packets automatically

## Common Issues

### Certificate Verification
Self-signed certificates will fail verification by default. Options:
- Set `verify_peer: false` in client config (testing only)
- Add the cert to the client's trusted CA bundle

### Connection Timeout
If the connection times out:
- Check server is running: `lsof -i :4433`
- Check firewall settings
- Verify client is connecting to correct address/port

### TLS Version Mismatch
QUIC requires TLS 1.3. Ensure both client and server support it.

## Debugging Tips

1. **Start simple**: Use `--no-retry` to simplify the handshake
2. **Use RUST_LOG=trace**: See every packet detail
3. **Compare with quiche-client**: Test server with known-good client
4. **Enable SSLKEYLOGFILE**: Decrypt packets in Wireshark
5. **Check connection IDs**: Ensure client and server agree on CIDs

---

## Running Tests

Quichex has three categories of tests with different requirements:

### Test Categories

| Category | Count | Server Required | Run Time | Command |
|----------|-------|-----------------|----------|---------|
| **Unit Tests** | ~120 | No | ~1-2 sec | `mix test --exclude integration --exclude stress` |
| **Integration Tests** | 23 | Yes | ~20 sec | `mix test test/quichex/active_passive_mode_test.exs` |
| **Stress Tests** | 10 | Yes | ~60-120 sec | `mix test --only stress` |

### Quick Test Commands

**Run all unit tests** (no server needed):
```bash
mix test --exclude integration --exclude stress
```

**Run all tests** (requires quiche-server running):
```bash
mix test
```

**Run specific test file**:
```bash
mix test test/quichex/state_test.exs
mix test test/quichex/stream_state_test.exs
```

**Run with coverage**:
```bash
mix test --cover
```

---

## Integration & Stress Tests

Integration and stress tests require a running quiche-server instance.

### Server Setup for Tests

The quiche-server must be built with BoringSSL submodules initialized:

**First-time setup** (one-time per quiche checkout):
```bash
cd ../quiche
git submodule update --init --recursive
```

**Build the server**:
```bash
cd ../quiche
cargo build --bin quiche-server
```

**Start server for tests**:
```bash
cd ../quiche
RUST_LOG=info cargo run --bin quiche-server -- \
  --listen 127.0.0.1:4433 \
  --root . \
  --no-retry
```

> **Note**: Leave the server running in a separate terminal while running integration/stress tests.

### Running Integration Tests

Integration tests verify active/passive mode behavior with real network connections:

```bash
# In a separate terminal, start the server first
cd ../quiche
RUST_LOG=info cargo run --bin quiche-server -- --listen 127.0.0.1:4433 --root . --no-retry

# Then run integration tests
mix test test/quichex/active_passive_mode_test.exs
```

**What's tested:**
- Active mode (automatic message delivery)
- Passive mode (explicit `stream_recv/3`)
- `:once` mode (one message then passive)
- Integer mode (`{:active, N}`)
- Dynamic mode switching with `setopts/2`
- Buffer behavior and FIN handling

---

## Phase 5 Stress Tests

Stress tests validate active/passive mode implementation under extreme load conditions.

### Test Coverage

**File**: `test/quichex/active_passive_stress_test.exs` (10 tests)

1. **Many Streams in Active Mode**
   - 100 concurrent streams
   - Rapid stream creation/closure (50 streams)

2. **Rapid setopts Switching**
   - 1000 consecutive mode switches
   - Mode switching during active data transfer

3. **Large Buffer in Passive Mode**
   - Buffer accumulation across 20 streams
   - Growth and drainage cycles

4. **Mixed Modes Across Streams**
   - 50 streams with different active modes
   - Consistent mode behavior across streams

5. **Edge Cases**
   - setopts on closed connection
   - Process death during data transfer

### Server Requirements for Stress Tests

Stress tests require **enhanced server configuration** due to higher concurrency:

```bash
cd ../quiche

# Initialize submodules (first time only)
git submodule update --init --recursive

# Start server with larger limits
RUST_LOG=info cargo run --bin quiche-server -- \
  --listen 127.0.0.1:4433 \
  --root . \
  --no-retry \
  --max-data 50000000 \
  --max-stream-data 10000000 \
  --max-streams-bidi 200
```

### Running Stress Tests

```bash
# Start enhanced server first (see above)

# Run only stress tests
mix test --only stress

# Run with verbose output
mix test --only stress --trace

# Run specific stress test
mix test test/quichex/active_passive_stress_test.exs:119  # Line number
```

### Expected Run Times

| Test | Approximate Time |
|------|------------------|
| 100 concurrent streams | ~30-60 seconds |
| 1000 setopts calls | ~15-30 seconds |
| Large buffer accumulation | ~20-40 seconds |
| Mixed modes (50 streams) | ~30-60 seconds |
| Edge cases | ~10-20 seconds |

**Total stress test suite**: ~2-3 minutes

### Troubleshooting Stress Tests

**Connection timeouts**:
- Ensure server has large enough limits (see command above)
- Check server logs for connection rejections
- Verify server is on correct port: `lsof -i :4433`

**Test failures**:
- Stress tests are timing-sensitive
- Server may be under heavy load
- Try running with `--trace` to see detailed output
- Check server logs for errors

**Server crashes**:
- Server may run out of resources under extreme load
- Increase server limits or reduce test concurrency
- Check system limits: `ulimit -n` (file descriptors)

### Configuration Tuning

Tests use enhanced client configuration matching server limits:

```elixir
config =
  Config.new!()
  |> Config.set_application_protos(["hq-interop"])
  |> Config.verify_peer(false)
  |> Config.set_max_idle_timeout(30_000)
  |> Config.set_initial_max_streams_bidi(200)
  |> Config.set_initial_max_data(50_000_000)
  |> Config.set_initial_max_stream_data_bidi_local(10_000_000)
  |> Config.set_initial_max_stream_data_bidi_remote(10_000_000)
```

### Test Tags

Stress tests use ExUnit tags for filtering:

- `@moduletag :stress` - Mark as stress test
- `@moduletag :integration` - Requires server
- `@tag timeout: 120_000` - Individual test timeout (2 minutes)

**Exclude stress tests**:
```bash
mix test --exclude stress
```

**Include only stress tests**:
```bash
mix test --only stress
```

**Exclude all integration tests** (both regular and stress):
```bash
mix test --exclude integration
```

---

## Test Results Summary

### Current Test Coverage

After Phase 5 completion:

```
Unit Tests (no server):        120 tests ✅
Integration Tests:              23 tests ✅ (with server)
Stress Tests (optional):        10 tests ✅ (with server)
─────────────────────────────────────────────────
Total:                         153 tests

Run time (unit only):          ~1-2 seconds
Run time (with integration):   ~20-25 seconds
Run time (with stress):        ~3-5 minutes
```

### Running the Full Test Suite

**Complete test run** (requires server):
```bash
# Terminal 1: Start server
cd ../quiche
RUST_LOG=info cargo run --bin quiche-server -- \
  --listen 127.0.0.1:4433 \
  --root . \
  --no-retry \
  --max-data 50000000 \
  --max-stream-data 10000000 \
  --max-streams-bidi 200

# Terminal 2: Run all tests including stress
mix test --include stress
```

**Expected output**:
```
Finished in X.X seconds
1 doctest, 158 tests, 0 failures
```

### CI/CD Considerations

For continuous integration:

**Fast CI** (unit tests only, ~1-2 seconds):
```bash
mix test --exclude integration --exclude stress
```

**Standard CI** (unit + integration, ~20-25 seconds):
```bash
# Requires server setup in CI environment
mix test --exclude stress
```

**Nightly/Weekly** (full suite with stress, ~3-5 minutes):
```bash
# Requires server with enhanced limits
mix test --include stress
```
