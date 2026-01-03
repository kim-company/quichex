defmodule Quichex.Native.PacketTest do
  use ExUnit.Case, async: true

  alias Quichex.Native
  alias Quichex.Native.PacketHeader

  test "parses generated version negotiation packets" do
    dcid = :crypto.strong_rand_bytes(16)
    scid = :crypto.strong_rand_bytes(16)
    assert {:ok, packet} = Native.version_negotiate(scid, dcid)
    assert {:ok, %PacketHeader{} = header} = Native.header_info(packet, byte_size(dcid))
    assert header.version == 0
    assert byte_size(header.dcid) == 16
    assert byte_size(header.scid) == 16
    assert header.token == nil
  end

  test "generates retry packets" do
    dcid = :crypto.strong_rand_bytes(16)
    scid = :crypto.strong_rand_bytes(16)
    token = :crypto.strong_rand_bytes(24)

    assert {:ok, retry_packet} = Native.retry(scid, dcid, scid, token, 1)
    assert is_binary(retry_packet)
  end

  test "rejects malformed headers" do
    assert {:error, _} = Native.header_info(<<0, 1, 2, 3>>, 16)
  end
end
