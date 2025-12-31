# Ensure the application is started before running tests
# This starts the ConnectionRegistry which is needed for server-side connections
{:ok, _} = Application.ensure_all_started(:quichex)

Logger.configure(level: :warning)

# Exclude external tests by default (tests that connect to cloudflare-quic.com)
# To run them: mix test --include external
ExUnit.start(exclude: [:external])
