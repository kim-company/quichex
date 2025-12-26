import Config

# Test environment - lower limits for faster tests
config :quichex,
  max_connections: 100,
  max_stream_handlers_per_connection: 50
