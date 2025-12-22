# Manual Test Scripts

This directory contains manual test scripts that are **not** part of the ExUnit test suite. These scripts are used for interactive testing, debugging, and integration testing with external QUIC servers.

## Scripts

### manual_server_test.exs
Full integration test against quiche-server. Tests connection establishment, stream operations, and data transfer.

**Usage**:
```bash
# Start quiche-server first
cd ../quiche && RUST_LOG=debug target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key \
  --listen 127.0.0.1:4433 --no-retry

# Run the test
mix run scripts/manual_server_test.exs
```

**Expected output**: Connection established, stream data sent and received, test passes.

### socket_debug.exs
Detailed socket-level debugging with extensive logging. Shows UDP packet flow, connection state changes, and stream operations.

**Usage**:
```bash
# Start quiche-server
cd ../quiche && RUST_LOG=trace target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key \
  --listen 127.0.0.1:4433 --no-retry

# Run the debug script
mix run scripts/socket_debug.exs
```

**Purpose**:
- Diagnose socket message delivery issues
- Verify UDP packet reception
- Debug connection establishment problems
- Inspect stream data flow

**Output**: Verbose logs showing every UDP message, connection state transition, and stream event.

### debug_test.exs
Simple message flow debugging test. Lighter weight than socket_debug.exs.

**Usage**:
```bash
# Start quiche-server
cd ../quiche && target/debug/quiche-server \
  --cert ../quichex/priv/cert.crt \
  --key ../quichex/priv/cert.key \
  --listen 127.0.0.1:4433 --no-retry

# Run the test
mix run scripts/debug_test.exs
```

## Why These Are Not ExUnit Tests

These scripts:
- Require external services (quiche-server) to be running
- Are interactive and may require manual intervention
- Are primarily for debugging, not for automated CI/CD
- Have variable output depending on server configuration
- May take longer to execute than typical unit tests

The main ExUnit test suite is in `test/` and can run without external dependencies.

## When to Use These Scripts

- **Development**: When adding new features or fixing bugs related to connection or stream handling
- **Debugging**: When investigating issues with packet flow, socket handling, or protocol state
- **Integration Testing**: When testing against different QUIC server implementations
- **Performance Testing**: When measuring latency or throughput characteristics

## See Also

- `TESTING.md` - Comprehensive guide to testing Quichex
- `BUGS_FIXED.md` - Documentation of bugs discovered using these scripts
- `CLEANUP_COMPLETE.md` - Cleanup performed after debugging session
