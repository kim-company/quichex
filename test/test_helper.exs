Logger.configure(level: :warning)

# Exclude external tests by default (tests that connect to cloudflare-quic.com)
# To run them: mix test --include external
ExUnit.start(exclude: [:external])
