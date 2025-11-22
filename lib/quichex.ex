defmodule Quichex do
  @moduledoc """
  Quichex - QUIC transport library for Elixir.

  Provides QUIC protocol support via Rustler bindings to cloudflare/quiche.
  Each QUIC connection runs in its own lightweight Elixir process, enabling
  massive concurrency with fault isolation.

  ## Features

  - Idiomatic Elixir API
  - Support for both client and server QUIC connections
  - Stream multiplexing (bidirectional and unidirectional)
  - Process-based concurrency model
  - Active/passive modes like :gen_tcp

  ## Quick Start

  See `Quichex.Connection` for client/server connection examples.
  See `Quichex.Config` for configuration options.
  """

  @version Mix.Project.config()[:version]

  @doc """
  Returns the Quichex version.
  """
  @spec version() :: String.t()
  def version, do: @version
end
