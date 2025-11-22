defmodule Quichex.Connection do
  @moduledoc """
  GenServer managing individual QUIC connections.

  Each connection runs in its own process for fault isolation and concurrency.
  Handles connection lifecycle, stream operations, and packet I/O.
  """

  use GenServer

  @doc """
  Starts a QUIC connection GenServer.

  ## Options

    * `:host` - Server hostname (client mode)
    * `:port` - Server port (client mode)
    * `:config` - Quichex.Config struct
    * `:active` - Active mode like :gen_tcp (default: true)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    # Will be implemented in Milestone 3
    {:ok, opts}
  end
end
