defmodule Quichex.Native.ConfigError do
  @moduledoc """
  Raised when a QUIC configuration call fails.
  """

  defexception [:message, :reason, :function]
end
