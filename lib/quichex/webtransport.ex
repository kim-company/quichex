defmodule Quichex.WebTransport do
  @moduledoc """
  Minimal WebTransport helpers built on top of `Quichex.H3`.
  """

  alias Quichex.H3

  @type header :: {binary(), binary()}
  @type connection :: reference()
  @type h3_connection :: reference()
  @type stream_id :: non_neg_integer()

  @doc """
  Build headers for a WebTransport CONNECT request.
  """
  @spec connect_headers(binary(), binary(), keyword()) :: [header()]
  def connect_headers(authority, path, opts \\ []) when is_binary(authority) and is_binary(path) do
    scheme = Keyword.get(opts, :scheme, "https")
    origin = Keyword.get(opts, :origin)
    user_agent = Keyword.get(opts, :user_agent)

    base = [
      {":method", "CONNECT"},
      {":scheme", scheme},
      {":authority", authority},
      {":path", path},
      {":protocol", "webtransport"}
    ]

    base
    |> maybe_add("origin", origin)
    |> maybe_add("user-agent", user_agent)
  end

  @doc """
  Send a WebTransport CONNECT request and return the stream id.
  """
  @spec connect(connection(), h3_connection(), binary(), binary(), keyword()) :: stream_id()
  def connect(conn, h3_conn, authority, path, opts \\ []) do
    headers = connect_headers(authority, path, opts)
    H3.send_request(conn, h3_conn, headers, true)
  end

  @doc """
  Extract the HTTP status code from response headers, if present.
  """
  @spec response_status([header()]) :: non_neg_integer() | nil
  def response_status(headers) when is_list(headers) do
    case Enum.find(headers, fn {name, _value} -> name == ":status" end) do
      {":status", value} ->
        case Integer.parse(value) do
          {status, _} -> status
          :error -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Send a WebTransport datagram on the given CONNECT stream id.
  """
  @spec send_datagram(connection(), stream_id(), binary()) :: :ok
  def send_datagram(conn, stream_id, payload) do
    H3.send_datagram(conn, stream_id, payload)
  end

  @doc """
  Receive a WebTransport datagram.

  Returns `{:ok, stream_id, payload}` or `:done`.
  """
  @spec recv_datagram(connection(), non_neg_integer()) ::
          {:ok, stream_id(), binary()} | :done
  def recv_datagram(conn, max_len) do
    H3.recv_datagram(conn, max_len)
  end

  defp maybe_add(headers, _name, nil), do: headers
  defp maybe_add(headers, name, value), do: headers ++ [{name, value}]
end
