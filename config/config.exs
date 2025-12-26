import Config

# Quichex global configuration
config :quichex,
  # Maximum number of concurrent QUIC connections
  max_connections: 10_000,
  # Maximum number of stream handlers per connection
  max_stream_handlers_per_connection: 1000

# Import environment-specific configuration
import_config "#{config_env()}.exs"
