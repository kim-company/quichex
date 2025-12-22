# Example Scripts

This directory contains example scripts demonstrating how to use Quichex.

## Scripts

### example.exs

A complete example showing how to:
- Connect to a local QUIC server (quiche-server)
- Perform the QUIC handshake
- Open a bidirectional stream
- Send an HTTP/0.9 request (hq-interop protocol)
- Receive and display the response

**Prerequisites**:

1. Build quiche-server (one-time setup):
   ```bash
   cd ../quiche
   cargo build --examples
   ```

2. Create content directory with test file (one-time setup):
   ```bash
   mkdir -p ../quiche/quiche/examples/root
   echo '<!DOCTYPE html><html><body><h1>Hello from Quiche!</h1></body></html>' > ../quiche/quiche/examples/root/index.html
   ```

3. Start quiche-server in a separate terminal:
   ```bash
   cd ../quiche/quiche
   RUST_LOG=info ../../target/debug/examples/server
   ```

   Note: The server listens on `127.0.0.1:4433` and serves files from `examples/root/`

**Usage**:
```bash
mix run scripts/example.exs
```

**Expected output** (when quiche-server is running):
```
=== Quichex Example: Local quiche-server ===

1. Connecting to 127.0.0.1:4433...
   (Make sure quiche-server is running!)
   ✓ Connection process started

2. Waiting for QUIC handshake to complete...
   ✓ Handshake complete!

Connection details:
  - Server: 127.0.0.1
  - Local:  {{0, 0, 0, 0}, 54321}
  - Remote: {{127, 0, 0, 1}, 4433}
  - Established: true

3. Opening bidirectional stream...
   ✓ Stream 0 opened

4. Sending HTTP/0.9 GET request...
   ✓ Request sent (18 bytes)

5. Waiting for response...
   (Active mode: messages sent automatically)

   ✓ Received response!
   Response (123 bytes):
   <!DOCTYPE html>
   <html>
   <head><title>quiche</title></head>
   <body>Hello from quiche!</body>
   </html>

   ✓ Stream FIN received

6. Closing connection...
   ✓ Connection closed

=== Example Complete ===
```

## Purpose

This script serves as:
- **Getting started guide** for new users
- **Integration test** against a real QUIC server
- **Reference implementation** showing best practices
- **Debugging aid** when troubleshooting connection issues

## Testing Against Public Servers

The integration tests (run with `mix test --only integration`) connect to **cloudflare-quic.com** and verify:
- Connection establishment
- Stream operations
- Data transfer
- Multiple concurrent streams

To run these tests:
```bash
mix test --only integration
```

## See Also

- `test/quichex/integration_test.exs` - Comprehensive integration tests
- `test/quichex/connection_test.exs` - Unit tests for Connection API
- `CLAUDE.md` - Development guide and conventions
- `CONSOLIDATION_SUMMARY.md` - Current project status
