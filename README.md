# Quichex

An Elixir library providing QUIC transport via Rustler bindings to [cloudflare/quiche](https://github.com/cloudflare/quiche).

Quichex leverages the BEAM's concurrency model where each QUIC connection runs in its own lightweight Elixir process, enabling massive concurrency with fault isolation.

## Features

- 🚀 **Idiomatic Elixir API** - Feels natural to BEAM developers
- 🔒 **Production-ready** - Proper supervision and error handling
- 🔄 **Client & Server** - Support for both QUIC connection modes
- 📊 **Stream Multiplexing** - Bidirectional and unidirectional streams
- ⚡ **High Performance** - Zero-copy where possible
- 📡 **Active/Passive Modes** - Similar to :gen_tcp/:gen_udp

## Status

⚠️ **Early Development** - This library is currently in active development (Milestone 1). Not yet ready for production use.

See [PLAN.md](PLAN.md) for the complete roadmap and implementation plan.

## Installation

Once published to Hex, the package can be installed by adding `quichex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:quichex, "~> 0.1.0"}
  ]
end
```

## Quick Example (Future API)

```elixir
# Client connection
config = Quichex.Config.new()
|> Quichex.Config.set_application_protos(["myproto"])

{:ok, conn} = Quichex.Connection.connect(
  host: "example.com",
  port: 4433,
  config: config
)

# Open a stream and send data
{:ok, stream_id} = Quichex.Connection.open_stream(conn, :bidirectional)
:ok = Quichex.Connection.stream_send(conn, stream_id, "Hello QUIC!", fin: true)

# Receive data (active mode)
receive do
  {:quic_stream, ^conn, ^stream_id, data} ->
    IO.puts("Received: #{data}")
end
```

## Architecture

See [CLAUDE.md](CLAUDE.md) for detailed architecture information.

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc):

```bash
mix docs
```

## License

BSD-2-Clause (same as cloudflare/quiche)

