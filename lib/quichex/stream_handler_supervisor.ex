defmodule Quichex.StreamHandlerSupervisor do
  @moduledoc """
  DynamicSupervisor managing StreamHandler processes for a single connection.

  One StreamHandlerSupervisor per connection, managing all stream handlers
  for that connection's streams.

  ## Configuration

  Max handlers configured per-connection or via application environment:

      config :quichex, max_stream_handlers_per_connection: 1000

  ## Lifecycle

  - Started by ConnectionSupervisor before Connection
  - Manages stream handler processes under :one_for_one strategy
  - All handlers are :temporary (never restarted)
  - Terminates when parent ConnectionSupervisor shuts down
  """

  use DynamicSupervisor

  @doc """
  Starts a StreamHandlerSupervisor with the given max_children limit.

  ## Arguments

    * `max_children` - Maximum number of concurrent stream handlers

  ## Returns

    * `{:ok, pid}` - Supervisor PID
    * `{:error, reason}` - On failure
  """
  @spec start_link(non_neg_integer()) :: Supervisor.on_start()
  def start_link(max_children) do
    DynamicSupervisor.start_link(__MODULE__, max_children)
  end

  @impl true
  def init(max_children) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: max_children
    )
  end
end
