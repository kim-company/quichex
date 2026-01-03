defmodule Quichex.StateTest do
  use ExUnit.Case, async: true

  alias Quichex.{State, StreamState}

  describe "stream classification helpers" do
    test "stream_type infers bidirectional vs unidirectional" do
      assert State.stream_type(0) == :bidirectional
      assert State.stream_type(4) == :bidirectional
      assert State.stream_type(2) == :unidirectional
      assert State.stream_type(3) == :unidirectional
    end

    test "stream_owner identifies local vs remote for client connections" do
      state = %State{connection_mode: :client}
      assert State.stream_owner(state, 0) == :local
      assert State.stream_owner(state, 2) == :local
      assert State.stream_owner(state, 1) == :remote
      assert State.stream_owner(state, 3) == :remote
    end

    test "stream_owner identifies local vs remote for server connections" do
      state = %State{connection_mode: :server}
      assert State.stream_owner(state, 1) == :local
      assert State.stream_owner(state, 3) == :local
      assert State.stream_owner(state, 0) == :remote
      assert State.stream_owner(state, 2) == :remote
    end
  end

  describe "get_or_create_stream/3" do
    test "sets direction to :recv for remote unidirectional streams" do
      state = %State{connection_mode: :server}
      {stream, new_state} = State.get_or_create_stream(state, 2, :unidirectional)

      assert %StreamState{type: :unidirectional, direction: :recv} = stream
      assert Map.has_key?(new_state.streams, 2)
    end

    test "sets direction to :send for local unidirectional streams" do
      state = %State{connection_mode: :client}
      {stream_id, state} = State.allocate_uni_stream(state)
      {stream, _state} = State.get_or_create_stream(state, stream_id, :unidirectional)

      assert stream.direction == :send
      assert stream.type == :unidirectional
    end
  end
end
