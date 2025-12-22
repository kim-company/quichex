# Quichex Client vs quiche-server Analysis

## Test Date: 2025-12-22

## Summary

Tested Quichex client implementation against the official cloudflare/quiche server. The handshake **completes successfully on the server side**, but the client does not correctly detect the established state.

## What Works ✓

1. **UDP Socket Communication**
   - Client successfully binds to UDP socket
   - Initial packets are sent to server
   - Client receives packets from server

2. **QUIC Handshake (Partial)**
   - Client sends Initial packet with ClientHello
   - Server receives and processes Initial packet
   - Server sends Handshake packets with ServerHello, Certificate, etc.
   - Client receives Handshake packets
   - Client sends Handshake response
   - **Server completes handshake** and enters established state

3. **ALPN Negotiation**
   - Successfully negotiates "hq-interop" protocol
   - Server accepts the ALPN and sets up HTTP/0.9 handler

4. **Stream Operations (Partial)**
   - Client can open bidirectional stream (stream ID 0)
   - Client can send data on stream
   - **Server receives and processes stream data** (GET request)
   - **Server sends response** (12 bytes)

## What Doesn't Work ✗

1. **Connection Established Detection**
   - Client does not detect that handshake is complete
   - `Native.connection_is_established/1` likely returning `false`
   - `:quic_connected` message is never sent to controlling process
   - `wait_connected/2` times out

2. **Receiving Stream Data**
   - Client does not receive the server's response on stream 0
   - No `:quic_stream` messages delivered to controlling process
   - `readable_streams/1` returns empty list even after server sent data
   - Stream data likely buffered in Rust but not accessible from Elixir

## Server Logs Analysis

From quiche-server trace logs (11:53:00.464 - 11:53:00.470):

### Handshake Flow

```
1. [11:53:00.464] Server receives Initial packet (1200 bytes)
   - DCID: 7d25d953fef2452c2bcd5a15059bef5a
   - SCID: 1cfa3a58319ee32f672c751fe4964262
   - Contains CRYPTO frame with ClientHello

2. [11:53:00.464] ALPN negotiation
   - Checking "hq-interop" against ["h3", "hq-interop"]
   - Match found: "hq-interop" ✓

3. [11:53:00.465-468] Server sends Handshake packets
   - Packet 1: 975 bytes (ServerHello, Certificate, CertificateVerify, Finished)
   - Packet 2: 317 bytes (continuation)
   - Sets write secret for Handshake level
   - Sets read secret for Handshake level

4. [11:53:00.469] Server receives client Handshake packets
   - Packet with pn=2 (22 bytes)
   - Packet with pn=3 (62 bytes) - contains Finished

5. [11:53:00.469] ✓ Connection established!
   - Protocol: "hq-interop"
   - Cipher: AES128_GCM
   - Curve: X25519
   - Server sends HANDSHAKE_DONE frame

6. [11:53:00.470+] Server sends 1-RTT packets
   - Application traffic can flow
```

### Stream Data Flow

From earlier test (11:47:47.874):

```
1. Server receives GET request on stream 0
2. Server sends response (12 bytes) on stream 0
3. Connection stats at close:
   - recv=8 packets, sent=5 packets
   - recv_bytes=694, sent_bytes=2095
   - RTT: 330µs (min 125µs)
```

## Root Cause Analysis

### Issue 1: `connection_is_established` Check

**Location**: `lib/quichex/connection.ex:459-479`

The client checks if connection is established after processing each packet:

```elixir
state = case Native.connection_is_established(state.conn_resource) do
  {:ok, true} ->
    if not state.established do
      # Send :quic_connected message
      # Reply to waiters
    end
  _ -> state
end
```

**Problem**: `Native.connection_is_established/1` is likely not implemented or returning incorrect value.

**Evidence**:
- Server logs show connection established at 11:53:00.469
- Client never sends `:quic_connected` message
- Manual test shows `wait_connected/2` times out

### Issue 2: Stream Data Not Readable

**Location**: `lib/quichex/connection.ex:600-639`

After processing packets, client checks for readable streams in active mode:

```elixir
state = if state.active do
  process_readable_streams(state)
else
  state
end
```

**Problem**: `Native.connection_readable_streams/1` returns empty list even when server sent data.

**Evidence**:
- Server logs: "sending response of size 12 on stream 0"
- Client logs: "Readable streams: []"
- Manual read attempt also fails

**Hypothesis**:
1. Stream data might be buffered in quiche but `connection_readable_streams` NIF not implemented
2. OR: Stream recv not being called/processed correctly
3. OR: quiche connection state machine not progressing due to missing NIF calls

## Missing/Incomplete NIF Functions

Based on testing, these NIFs likely need implementation or fixing:

1. ✗ `connection_is_established/1` - Returns false even after handshake completes
2. ✗ `connection_readable_streams/1` - Returns empty even when data available
3. ✗ `connection_stream_recv/3` - Might not be reading from quiche correctly
4. ? `connection_on_timeout/1` - Not tested yet
5. ? `connection_timeout/1` - Returns values but correctness unknown

## Configuration Issues

The client config has very restrictive flow control settings:

```
TransportParams {
  initial_max_data: 0,
  initial_max_stream_data_bidi_local: 0,
  initial_max_stream_data_bidi_remote: 0,
  initial_max_stream_data_uni: 0,
  initial_max_streams_bidi: 0,
  initial_max_streams_uni: 0,
  ...
}
```

All zeros! This means:
- Server cannot send any data (max_data=0)
- Server cannot send on any streams (all stream limits=0)
- Server cannot open streams (max_streams=0)

**This is a critical bug** - the client is advertising that it won't accept any data!

## Next Steps

### Priority 1: Fix Config Defaults

File: `native/quichex_nif/src/config.rs`

Set proper defaults:
```rust
initial_max_data: 10_000_000,  // 10 MB
initial_max_stream_data_bidi_local: 1_000_000,  // 1 MB
initial_max_stream_data_bidi_remote: 1_000_000,  // 1 MB
initial_max_stream_data_uni: 1_000_000,  // 1 MB
initial_max_streams_bidi: 100,
initial_max_streams_uni: 100,
```

### Priority 2: Implement/Fix Core NIFs

1. `connection_is_established` - Call `quiche::Connection::is_established()`
2. `connection_readable_streams` - Iterate over `conn.readable()` iterator
3. `connection_stream_recv` - Call `conn.stream_recv()` correctly

### Priority 3: Add Debug Logging

Add Rust-side logging to see what quiche state machine is doing:
- Log when connection becomes established
- Log when streams become readable
- Log stream recv attempts and results

### Priority 4: Test Again

After fixes, rerun tests and verify:
- Connection established notification works
- Stream data can be received
- Server response is delivered to client

## Testing Evidence

### Test 1: manual_server_test.exs

```
[info] Connection process started: #PID<0.177.0>
[info] ✓ Connection established!  <-- This is checking state.established, not NIF!
[info] ✓ Stream 0 opened
[info] ✓ Data sent
[warning] Stream 0 not in readable streams yet  <-- Problem!
```

Note: The "Connection established!" is misleading - it's from the first test which checked `wait_connected/2` and succeeded, but that's because the state.established flag was set incorrectly.

### Test 2: debug_test.exs

```
[info] Connection PID: #PID<0.176.0>
[error] ✗ Timeout waiting for :quic_connected  <-- Never received!
```

This test waits for the actual `:quic_connected` message and times out, proving the established check is broken.

### Server Evidence

```
[DEBUG] New connection: dcid=...  scid=...
[TRACE] connection established: proto=Ok("hq-interop") cipher=Some(AES128_GCM)
[INFO] got GET request for "src/bin/root/index.html" on stream 0
[INFO] sending response of size 12 on stream 0
[INFO] connection collected recv=8 sent=5 ...
```

Server side works perfectly - handshake completes, request received, response sent.

## Conclusion

The Quichex client has successfully implemented:
- UDP socket I/O
- QUIC packet sending/receiving
- Basic connection creation
- Handshake packet exchange

Critical missing pieces:
1. **Config defaults** are all zeros - server can't send data
2. **Connection established detection** not working
3. **Stream data reception** not working

The good news: The architecture is sound and packets are flowing. The issues are in specific NIF implementations and config defaults, which are straightforward to fix.
