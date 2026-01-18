# Quichex

Quichex exposes the [cloudflare/quiche](https://github.com/cloudflare/quiche)
QUIC implementation to Elixir via Rustler. The public API currently lives under
`Quichex.Native`, providing direct access to connection/configuration/packet
helpers. Most calls return `{:ok, term}` / `{:error, reason}` tuples, while
config setters return the config reference and raise `Quichex.Native.ConfigError`
on failure.

## Capabilities

- Build QUIC client and server connections directly from Elixir, including TLS
  configuration and datagram support.
- Create HTTP/3 connections and exchange request/response headers and bodies.
- Build WebTransport CONNECT headers and send/receive WebTransport datagrams.
- Inspect negotiated transport parameters, runtime stats, connection IDs, and
  peer errors via strongly typed structs.
- Drive streams and datagrams using either in-VM helpers (see
  `test/quichex/native/connection_test.exs`) or real UDP sockets (see the
  `:socket`-based integration test).
- Capture and reuse TLS session blobs for fast resumption, and toggle keylog
  paths for debugging.

## Example Workflow

```elixir
alias Quichex.Native.TestHelpers

{_, client} = TestHelpers.create_connection()
{_, server} = TestHelpers.accept_connection()

:ok = TestHelpers.ok!(Quichex.Native.connection_stream_send(client, 0, "hi", true))
```

## HTTP/3 Example

```elixir
alias Quichex.H3

# assumes `conn` is an established QUIC connection
h3_config = H3.config_new()
h3_conn = H3.conn_new_with_transport(conn, h3_config)

stream_id =
  H3.send_request(conn, h3_conn, [
    {":method", "GET"},
    {":scheme", "https"},
    {":authority", "localhost"},
    {":path", "/"}
  ], true)

_ = H3.conn_poll(conn, h3_conn)
```

## WebTransport Example

```elixir
alias Quichex.WebTransport

# assumes `conn` + `h3_conn` are ready for HTTP/3
stream_id = WebTransport.connect(conn, h3_conn, "localhost", "/moq")
WebTransport.send_datagram(conn, stream_id, "ping")
```

## Testing

All tests can be run with:

```bash
mix test
```

External HTTP/3 integration tests can be run with:

```bash
QUICHEX_INTEGRATION=1 mix test test/quichex/h3_integration_test.exs
```

The suite exercises:

- Unit coverage for metadata, datagram helpers, packet helpers, and error cases.
- Deterministic client/server simulations that exchange streams and datagrams.
- A `:socket`-based test that routes packets through real OS UDP sockets to
  catch wiring regressions.
- TLS session resumption, transport parameter validation, stats aggregation, and
  failure scenarios (invalid shutdown directions, zero-length datagram reads,
  post-close stream sends).

Refer to `test/quichex/native/connection_test.exs` for examples showing how to
create configs, accept connections, and pump packets between peers entirely from
Elixir.
