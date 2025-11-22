defmodule Quichex.Native.Error do
  @moduledoc """
  Exception raised when a NIF operation fails.

  This exception wraps errors returned from the Rust NIFs,
  providing structured error information.
  """

  defexception [:message, :operation, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          operation: atom(),
          reason: String.t()
        }

  @doc """
  Creates a new NIF error.

  ## Parameters

    * `operation` - The NIF operation that failed (e.g., `:config_new`, `:config_set_application_protos`)
    * `reason` - The error reason returned from the NIF

  ## Examples

      iex> raise Quichex.Native.Error, operation: :config_new, reason: "Invalid version"
      ** (Quichex.Native.Error) NIF operation :config_new failed: Invalid version

  """
  @impl true
  def exception(opts) do
    operation = Keyword.fetch!(opts, :operation)
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      message: "NIF operation #{inspect(operation)} failed: #{reason}",
      operation: operation,
      reason: reason
    }
  end

  @doc """
  Returns the exception message.
  """
  @impl true
  def message(%__MODULE__{message: message}) do
    message
  end
end
