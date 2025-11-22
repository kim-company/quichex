defmodule Quichex.Config do
  @moduledoc """
  Configuration for QUIC connections.

  Provides a builder pattern for ergonomic configuration of QUIC parameters
  including application protocols, flow control, congestion control, and TLS settings.
  """

  defstruct [:resource]

  @type t :: %__MODULE__{
          resource: reference() | nil
        }

  @doc """
  Creates a new QUIC configuration with default settings.

  ## Examples

      iex> config = Quichex.Config.new()
      iex> is_struct(config, Quichex.Config)
      true

  """
  @spec new(keyword()) :: t()
  def new(_opts \\ []) do
    # Will be implemented with NIF calls in Milestone 2
    %__MODULE__{resource: nil}
  end
end
