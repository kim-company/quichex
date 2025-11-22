defmodule Quichex.Native do
  @moduledoc false
  # Internal module for Rustler NIFs

  use Rustler,
    otp_app: :quichex,
    crate: :quichex_nif

  # Example NIF - will be replaced with actual QUIC NIFs
  def add(_a, _b), do: error()

  defp error, do: :erlang.nif_error(:nif_not_loaded)
end
