defmodule Quichex.WebTransportTest do
  use ExUnit.Case, async: true

  alias Quichex.WebTransport

  test "connect_headers builds required fields" do
    headers = WebTransport.connect_headers("example.com", "/moq")

    assert {":method", "CONNECT"} in headers
    assert {":scheme", "https"} in headers
    assert {":authority", "example.com"} in headers
    assert {":path", "/moq"} in headers
    assert {":protocol", "webtransport"} in headers
  end

  test "connect_headers adds optional headers" do
    headers =
      WebTransport.connect_headers("example.com", "/moq",
        origin: "https://example.com",
        user_agent: "quichex-test"
      )

    assert {"origin", "https://example.com"} in headers
    assert {"user-agent", "quichex-test"} in headers
  end

  test "response_status returns parsed status code" do
    headers = [
      {":status", "200"},
      {"server", "example"}
    ]

    assert WebTransport.response_status(headers) == 200
  end

  test "response_status returns nil on invalid status" do
    headers = [
      {":status", "oops"}
    ]

    assert WebTransport.response_status(headers) == nil
  end
end
