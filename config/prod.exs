import Config

# Production environment - high limits for production workloads
config :quichex,
  max_connections: 100_000,
  max_stream_handlers_per_connection: 5000
