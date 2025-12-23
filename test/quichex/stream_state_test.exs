defmodule Quichex.StreamStateTest do
  use ExUnit.Case, async: true

  alias Quichex.StreamState

  describe "buffer_data/3" do
    test "adds data without FIN to empty buffer" do
      stream = %StreamState{stream_id: 0, buffer: []}
      stream = StreamState.buffer_data(stream, "hello", false)

      assert stream.buffer == [{"hello", false}]
    end

    test "adds data with FIN to empty buffer" do
      stream = %StreamState{stream_id: 0, buffer: []}
      stream = StreamState.buffer_data(stream, "final", true)

      assert stream.buffer == [{"final", true}]
    end

    test "multiple calls append in order" do
      stream = %StreamState{stream_id: 0, buffer: []}
      stream = StreamState.buffer_data(stream, "first", false)
      stream = StreamState.buffer_data(stream, "second", false)
      stream = StreamState.buffer_data(stream, "third", false)

      assert stream.buffer == [
               {"first", false},
               {"second", false},
               {"third", false}
             ]
    end

    test "preserves FIN flag per entry" do
      stream = %StreamState{stream_id: 0, buffer: []}
      stream = StreamState.buffer_data(stream, "chunk1", false)
      stream = StreamState.buffer_data(stream, "chunk2", true)
      stream = StreamState.buffer_data(stream, "chunk3", false)

      assert stream.buffer == [
               {"chunk1", false},
               {"chunk2", true},
               {"chunk3", false}
             ]
    end

    test "handles empty binary" do
      stream = %StreamState{stream_id: 0, buffer: []}
      stream = StreamState.buffer_data(stream, "", false)

      assert stream.buffer == [{"", false}]
    end

    test "handles FIN-only entry (zero bytes)" do
      stream = %StreamState{stream_id: 0, buffer: []}
      stream = StreamState.buffer_data(stream, "", true)

      assert stream.buffer == [{"", true}]
    end

    test "appends to non-empty buffer" do
      stream = %StreamState{stream_id: 0, buffer: [{"existing", false}]}
      stream = StreamState.buffer_data(stream, "new", false)

      assert stream.buffer == [{"existing", false}, {"new", false}]
    end
  end

  describe "drain_buffer/2" do
    test "drains all data when max_len exceeds buffer size" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"hello", false}, {" world", false}]
      }

      {drained, updated_stream} = StreamState.drain_buffer(stream, 100)

      assert drained == [{"hello", false}, {" world", false}]
      assert updated_stream.buffer == []
    end

    test "drains partial data when max_len less than buffer size" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"hello", false}, {" world", false}]
      }

      # "hello" is 5 bytes, so max_len=5 should drain only first entry
      {drained, updated_stream} = StreamState.drain_buffer(stream, 5)

      assert drained == [{"hello", false}]
      assert updated_stream.buffer == [{" world", false}]
    end

    test "respects entry boundaries (doesn't split entries)" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"hello", false}, {"world", false}]
      }

      # max_len=7 is between "hello" (5 bytes) and "hello"+"world" (10 bytes)
      # Should drain only "hello" to respect boundaries
      {drained, updated_stream} = StreamState.drain_buffer(stream, 7)

      assert drained == [{"hello", false}]
      assert updated_stream.buffer == [{"world", false}]
    end

    test "preserves FIN flag in drained data" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"chunk1", false}, {"chunk2", true}, {"chunk3", false}]
      }

      {drained, updated_stream} = StreamState.drain_buffer(stream, 20)

      assert drained == [{"chunk1", false}, {"chunk2", true}, {"chunk3", false}]
      assert updated_stream.buffer == []
    end

    test "handles FIN in middle of buffer" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"first", false}, {"second", true}, {"third", false}]
      }

      # Drain first two entries
      {drained, updated_stream} = StreamState.drain_buffer(stream, 11)

      assert drained == [{"first", false}, {"second", true}]
      assert updated_stream.buffer == [{"third", false}]
    end

    test "drains empty buffer returns empty list" do
      stream = %StreamState{stream_id: 0, buffer: []}
      {drained, updated_stream} = StreamState.drain_buffer(stream, 100)

      assert drained == []
      assert updated_stream.buffer == []
    end

    test "multiple drain calls work correctly" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"a", false}, {"b", false}, {"c", false}]
      }

      # First drain
      {drained1, stream} = StreamState.drain_buffer(stream, 1)
      assert drained1 == [{"a", false}]
      assert stream.buffer == [{"b", false}, {"c", false}]

      # Second drain
      {drained2, stream} = StreamState.drain_buffer(stream, 1)
      assert drained2 == [{"b", false}]
      assert stream.buffer == [{"c", false}]

      # Third drain
      {drained3, stream} = StreamState.drain_buffer(stream, 1)
      assert drained3 == [{"c", false}]
      assert stream.buffer == []
    end

    test "handles zero max_len" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"hello", false}]
      }

      {drained, updated_stream} = StreamState.drain_buffer(stream, 0)

      assert drained == []
      assert updated_stream.buffer == [{"hello", false}]
    end

    test "drains FIN-only entry (zero bytes)" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"", true}]
      }

      {drained, updated_stream} = StreamState.drain_buffer(stream, 100)

      assert drained == [{"", true}]
      assert updated_stream.buffer == []
    end

    test "stops at exact buffer size boundary" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"hello", false}, {"world", false}]
      }

      # Exactly 5 bytes should drain first entry
      {drained, updated_stream} = StreamState.drain_buffer(stream, 5)

      assert drained == [{"hello", false}]
      assert updated_stream.buffer == [{"world", false}]
    end
  end

  describe "buffer_size/1" do
    test "empty buffer returns 0" do
      stream = %StreamState{stream_id: 0, buffer: []}
      assert StreamState.buffer_size(stream) == 0
    end

    test "single entry returns correct size" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"hello", false}]
      }

      assert StreamState.buffer_size(stream) == 5
    end

    test "multiple entries sum correctly" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"hello", false}, {" world", false}]
      }

      assert StreamState.buffer_size(stream) == 11
    end

    test "includes entries with FIN" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"chunk1", false}, {"chunk2", true}, {"chunk3", false}]
      }

      assert StreamState.buffer_size(stream) == 18
    end

    test "handles zero-byte entries" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"", false}, {"data", false}, {"", true}]
      }

      assert StreamState.buffer_size(stream) == 4
    end

    test "handles large buffer" do
      large_chunk = String.duplicate("x", 10_000)

      stream = %StreamState{
        stream_id: 0,
        buffer: [
          {large_chunk, false},
          {large_chunk, false},
          {large_chunk, false}
        ]
      }

      assert StreamState.buffer_size(stream) == 30_000
    end
  end

  describe "has_buffered_data?/1" do
    test "returns false for empty buffer" do
      stream = %StreamState{stream_id: 0, buffer: []}
      assert StreamState.has_buffered_data?(stream) == false
    end

    test "returns true for non-empty buffer" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"data", false}]
      }

      assert StreamState.has_buffered_data?(stream) == true
    end

    test "returns true even with zero-byte entry (FIN-only)" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"", true}]
      }

      assert StreamState.has_buffered_data?(stream) == true
    end

    test "returns true for multiple entries" do
      stream = %StreamState{
        stream_id: 0,
        buffer: [{"a", false}, {"b", false}]
      }

      assert StreamState.has_buffered_data?(stream) == true
    end
  end

  describe "buffer integration scenarios" do
    test "buffer-then-drain-all workflow" do
      stream = %StreamState{stream_id: 0, buffer: []}

      # Buffer some data
      stream = StreamState.buffer_data(stream, "first", false)
      stream = StreamState.buffer_data(stream, "second", false)
      stream = StreamState.buffer_data(stream, "third", true)

      assert StreamState.has_buffered_data?(stream) == true
      assert StreamState.buffer_size(stream) == 16

      # Drain all
      {drained, stream} = StreamState.drain_buffer(stream, 100)

      assert length(drained) == 3
      assert StreamState.has_buffered_data?(stream) == false
      assert StreamState.buffer_size(stream) == 0
    end

    test "buffer-then-drain-partial workflow" do
      stream = %StreamState{stream_id: 0, buffer: []}

      # Buffer data
      stream = StreamState.buffer_data(stream, "chunk1", false)
      stream = StreamState.buffer_data(stream, "chunk2", false)
      stream = StreamState.buffer_data(stream, "chunk3", false)

      # Drain first two
      {drained, stream} = StreamState.drain_buffer(stream, 12)
      assert length(drained) == 2

      # Still has data
      assert StreamState.has_buffered_data?(stream) == true
      assert StreamState.buffer_size(stream) == 6

      # Drain remaining
      {drained, stream} = StreamState.drain_buffer(stream, 10)
      assert length(drained) == 1
      assert StreamState.has_buffered_data?(stream) == false
    end

    test "handles mix of sizes and FIN flags" do
      stream = %StreamState{stream_id: 0, buffer: []}

      # Add various data patterns
      stream = StreamState.buffer_data(stream, "", false)
      # zero bytes
      stream = StreamState.buffer_data(stream, "x", false)
      # 1 byte
      stream = StreamState.buffer_data(stream, "hello", true)
      # 5 bytes with FIN
      stream = StreamState.buffer_data(stream, String.duplicate("a", 100), false)
      # 100 bytes

      assert StreamState.buffer_size(stream) == 106

      # Drain with small max_len
      {drained, stream} = StreamState.drain_buffer(stream, 6)

      # Should get: {"", false}, {"x", false}, {"hello", true}
      assert length(drained) == 3
      assert StreamState.buffer_size(stream) == 100
    end
  end
end
