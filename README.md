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

## Testing

All tests can be run with:

```bash
mix test
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
