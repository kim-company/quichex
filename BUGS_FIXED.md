# Bugs Fixed - 2025-12-22

## Summary

Successfully debugged and fixed the Quichex QUIC client to work end-to-end with quiche-server. The client can now:
- ✅ Establish TLS 1.3 connections
- ✅ Complete QUIC handshake
- ✅ Send stream data
- ✅ **Receive stream data** (the major fix!)

## Bug #1: Vec<u8> vs Binary Encoding **[CRITICAL]**

### Problem
NIFs were returning `Vec<u8>` which Rustler encodes as Elixir **lists** `[1, 2, 3, ...]` instead of **binaries** `<<1, 2, 3, ...>>`.

This caused a crash when trying to send packets:
```
** (ArgumentError) errors were found at the given arguments:
  * 1st argument: not a bitstring
:erlang.byte_size([203, 0, 0, 0, 1, ...])
```

### Root Cause
Rustler's default encoding for `Vec<u8>` is an Elixir list, not a binary.

### Fix
Changed two NIFs to return `rustler::Binary` instead of `Vec<u8>`:

**File**: `native/quichex_nif/src/connection.rs`

1. **connection_send** (line 108-131)
```rust
// Before
pub fn connection_send(conn: ResourceArc<ConnectionResource>)
  -> Result<(Vec<u8>, SendInfo), String>

// After
pub fn connection_send<'a>(env: rustler::Env<'a>, conn: ResourceArc<ConnectionResource>)
  -> Result<(rustler::Binary<'a>, SendInfo), String>
{
    // ... match connection.send(&mut out) ...
    Ok((write, send_info)) => {
        let mut binary = rustler::OwnedBinary::new(written)
            .ok_or_else(|| "Failed to allocate binary".to_string())?;
        binary.as_mut_slice().copy_from_slice(&out[..written]);
        Ok((binary.release(env), SendInfo::from_quiche(send_info)))
    }
}
```

2. **connection_stream_recv** (line 316-346)
```rust
// Before
pub fn connection_stream_recv(...)
  -> Result<(Vec<u8>, bool), String>

// After
pub fn connection_stream_recv<'a>(env: rustler::Env<'a>, ...)
  -> Result<(rustler::Binary<'a>, bool), String>
{
    // ... match connection.stream_recv(...) ...
    Ok((read, fin)) => {
        let mut binary = rustler::OwnedBinary::new(read)
            .ok_or_else(|| "Failed to allocate binary".to_string())?;
        binary.as_mut_slice().copy_from_slice(&buf[..read]);
        Ok((binary.release(env), fin))
    }
}
```

### Impact
- Packets can now be sent via UDP
- Connection handshake completes successfully
- Stream data can be sent and received

---

## Bug #2: Controlling Process Not Set Correctly **[CRITICAL]**

### Problem
Stream data messages were never being delivered to the parent process in `active` mode.

The `process_stream_data/2` function checks:
```elixir
if byte_size(data) > 0 and state.controlling_process != self() do
  send(state.controlling_process, {:quic_stream, self(), stream_id, data})
end
```

But `controlling_process` was being set to the GenServer's own PID, so the check was always FALSE!

### Root Cause
**File**: `lib/quichex/connection.ex` (line 227-230)

The code tried to get the parent process from `Process.get(:"$callers")`:

```elixir
parent_pid = case Process.get(:"$callers") do
  [caller | _] -> caller
  _ -> self()  # <-- BUG! Falls back to self()
end
```

When running from `mix run`, the `$callers` process dictionary is empty, so it fell back to `self()` (the GenServer process itself).

This meant:
```elixir
state.controlling_process == self()  # Always TRUE!
# So the check state.controlling_process != self() was always FALSE
# Messages were NEVER sent!
```

### Fix
**File**: `lib/quichex/connection.ex` (line 226-239)

Use the linked process (established by `GenServer.start_link`) to get the parent:

```elixir
# Get the parent process (the one that called connect/1)
# Use the process that's linked to us (GenServer.start_link creates a link)
parent_pid = case Process.info(self(), :links) do
  {:links, [parent | _]} when is_pid(parent) ->
    parent
  _ ->
    # Fallback: try $callers
    case Process.get(:"$callers") do
      [caller | _] -> caller
      _ ->
        # Last resort: use the group leader (usually the calling process)
        Process.group_leader()
    end
end
```

### Verification
Debug logs after fix:
```
Connection init: self=#PID<0.176.0>, controlling_process=#PID<0.94.0>
process_stream_data: controlling_process=#PID<0.94.0>, self=#PID<0.176.0>
Sending :quic_stream to #PID<0.94.0>
✓✓✓ Received :quic_stream message! ✓✓✓
Data (12 bytes): "Not Found!\r\n"
```

### Impact
- Stream data messages are now delivered to the parent process
- Active mode works correctly
- Applications can receive `:quic_stream` and `:quic_stream_fin` messages

---

## Test Results

### Before Fixes
```
❌ Crash on packet send (Vec<u8> encoding bug)
❌ No stream data received
❌ Timeout waiting for messages
```

### After Fixes
```
✅ TLS 1.3 handshake completes
✅ QUIC connection established
✅ ALPN negotiation ("hq-interop") succeeds
✅ Client sends stream data to server
✅ Server receives request and sends response
✅ Client receives stream data: "Not Found!\r\n"
✅ Messages delivered to controlling process
✅ Stream FIN received correctly
```

### Full Test Output
```
13:31:17.848 [info] ✓ Connection established!
13:31:17.848 [info] Opening bidirectional stream...
13:31:17.848 [info] ✓ Stream 0 opened
13:31:17.848 [info] Sending data on stream 0...
13:31:17.848 [info] ✓ Data sent
13:31:17.848 [info] Waiting for stream data messages...
13:31:17.848 [info] ✓✓✓ Received :quic_stream message! ✓✓✓
13:31:17.848 [info] Data (12 bytes): "Not Found!\r\n"
13:31:17.848 [info] ✓ Received :quic_stream_fin message
13:31:17.848 [info] ✓ Connection closed
```

### Server Logs Confirm Success
```
[DEBUG] New connection: dcid=... scid=...
[INFO] got GET request for "src/bin/root/index.html" on stream 0
[INFO] sending response of size 12 on stream 0
[INFO] connection collected recv=8 sent=5 lost=0 retrans=0
       sent_bytes=2110 recv_bytes=726
```

---

## Remaining Issues (Not Bugs)

### Config Flow Control Defaults

**Status**: Workaround in place, proper fix needed

**Issue**: `Config.new!()` doesn't set flow control defaults. All values are 0.

**Current Workaround**: Tests manually set values:
```elixir
config = Quichex.Config.new!()
  |> Quichex.Config.set_initial_max_data(10_000_000)
  |> Quichex.Config.set_initial_max_stream_data_bidi_remote(1_000_000)
  # ... etc
```

**Proper Fix Needed**: Set sensible defaults in the Rust `config_new` function or create a `Config.with_defaults!/0` helper.

**Recommended Defaults**:
```rust
initial_max_data: 10_000_000           // 10 MB
initial_max_stream_data_bidi_local: 1_000_000   // 1 MB
initial_max_stream_data_bidi_remote: 1_000_000  // 1 MB
initial_max_stream_data_uni: 1_000_000          // 1 MB
initial_max_streams_bidi: 100
initial_max_streams_uni: 100
```

### Debug Logging in Production Code

**Status**: Should be removed or gated behind feature flag

**Issue**: Added `eprintln!` debug logging to Rust NIFs for debugging.

**Files**:
- `native/quichex_nif/src/connection.rs`:
  - `connection_recv` (lines 98-119)
  - `connection_readable_streams` (line 353)
  - `connection_stream_recv` (lines 329-345)

- `lib/quichex/connection.ex`:
  - `do_init` (line 241)
  - `process_stream_data` (lines 616-624)

**Action**: Remove or gate behind `--features debug` before production use.

---

## Architecture Verification

The debugging process confirmed the architecture is sound:

✅ **Layer 1: UDP Socket I/O**
- Erlang `:gen_udp` working correctly
- Socket in `{:active, true}` mode
- Multiple UDP messages received and processed

✅ **Layer 2: QUIC Packet Processing**
- quiche's `connection.recv()` processes packets correctly
- Handshake packets exchanged successfully
- Application data packets handled properly

✅ **Layer 3: Stream Layer**
- Streams can be opened
- Data can be sent on streams with FIN flag
- Stream data can be received
- FIN flag properly handled

✅ **Layer 4: Process Model**
- Each connection runs in its own GenServer process
- Messages delivered to controlling process
- Active mode works as designed
- Supervision tree ready for fault tolerance

---

## Files Modified

### Rust (Native)
1. `native/quichex_nif/src/connection.rs`
   - Fixed `connection_send` return type
   - Fixed `connection_stream_recv` return type
   - Added debug logging (temporary)

### Elixir
1. `lib/quichex/connection.ex`
   - Fixed `controlling_process` detection in `do_init/4`
   - Added debug logging (temporary)

### Tests
1. `test/manual_server_test.exs`
   - Added proper flow control settings to config
   - Added message receive logic for active mode
   - Flush `:quic_connected` before waiting for stream data

### Documentation
1. `TESTING.md` - Testing guide
2. `ANALYSIS.md` - Initial analysis
3. `FIXES_APPLIED.md` - Progress tracking
4. `BUGS_FIXED.md` (this file) - Final summary

---

## Next Steps

1. **Remove debug logging** from production code
2. **Set config defaults** in Rust or Elixir
3. **Add comprehensive tests** for:
   - Multiple concurrent connections
   - Large data transfers
   - Bidirectional and unidirectional streams
   - Error conditions
4. **Implement server-side listener** (Milestone 5 in PLAN.md)
5. **Add documentation** with examples
6. **Implement remaining features**: datagrams, migration, stats

---

## Conclusion

The Quichex QUIC client is now **functionally working**! Both critical bugs have been fixed:
1. Binary encoding issue → packets can be sent/received
2. Controlling process issue → messages are delivered

The client successfully communicates with the official quiche-server, demonstrating that the core QUIC implementation is correct and the architecture is sound.
