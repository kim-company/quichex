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
