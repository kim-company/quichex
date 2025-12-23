defmodule Quichex.StateTest do
  use ExUnit.Case, async: true

  alias Quichex.State

  describe "set_active/2" do
    test "sets active mode to true with infinity count" do
      state = %State{active: false, active_count: 0}
      new_state = State.set_active(state, true)

      assert new_state.active == true
      assert new_state.active_count == :infinity
    end

    test "sets active mode to false with zero count" do
      state = %State{active: true, active_count: :infinity}
      new_state = State.set_active(state, false)

      assert new_state.active == false
      assert new_state.active_count == 0
    end

    test "sets active mode to :once with count of 1" do
      state = %State{active: false, active_count: 0}
      new_state = State.set_active(state, :once)

      assert new_state.active == :once
      assert new_state.active_count == 1
    end

    test "sets active mode to positive integer with same count" do
      state = %State{active: false, active_count: 0}
      new_state = State.set_active(state, 5)

      assert new_state.active == 5
      assert new_state.active_count == 5
    end

    test "handles setting to same mode" do
      state = %State{active: true, active_count: :infinity}
      new_state = State.set_active(state, true)

      assert new_state.active == true
      assert new_state.active_count == :infinity
    end

    test "transitions from :once to true" do
      state = %State{active: :once, active_count: 1}
      new_state = State.set_active(state, true)

      assert new_state.active == true
      assert new_state.active_count == :infinity
    end

    test "transitions from integer mode to :once" do
      state = %State{active: 5, active_count: 3}
      new_state = State.set_active(state, :once)

      assert new_state.active == :once
      assert new_state.active_count == 1
    end

    test "sets large integer count" do
      state = %State{active: false, active_count: 0}
      new_state = State.set_active(state, 1000)

      assert new_state.active == 1000
      assert new_state.active_count == 1000
    end
  end

  describe "decrement_active_count/1" do
    test "decrements positive count by 1" do
      state = %State{active: 5, active_count: 5}
      new_state = State.decrement_active_count(state)

      assert new_state.active_count == 4
      assert new_state.active == 5
    end

    test "decrements count from 2 to 1" do
      state = %State{active: :once, active_count: 2}
      new_state = State.decrement_active_count(state)

      assert new_state.active_count == 1
    end

    test "decrements count from 1 to 0 and switches mode to false" do
      state = %State{active: :once, active_count: 1}
      new_state = State.decrement_active_count(state)

      assert new_state.active_count == 0
      assert new_state.active == false
    end

    test "count at 0 stays at 0" do
      state = %State{active: false, active_count: 0}
      new_state = State.decrement_active_count(state)

      assert new_state.active_count == 0
      assert new_state.active == false
    end

    test "infinity count stays infinity" do
      state = %State{active: true, active_count: :infinity}
      new_state = State.decrement_active_count(state)

      assert new_state.active_count == :infinity
      assert new_state.active == true
    end

    test "integer mode switches to false when count reaches 0" do
      state = %State{active: 5, active_count: 1}
      new_state = State.decrement_active_count(state)

      assert new_state.active_count == 0
      assert new_state.active == false
    end

    test "large count decrements correctly" do
      state = %State{active: 1000, active_count: 1000}
      new_state = State.decrement_active_count(state)

      assert new_state.active_count == 999
      assert new_state.active == 1000
    end
  end

  describe "should_deliver_messages?/1" do
    test "returns true for active: true" do
      state = %State{active: true, active_count: :infinity}
      assert State.should_deliver_messages?(state) == true
    end

    test "returns false for active: false" do
      state = %State{active: false, active_count: 0}
      assert State.should_deliver_messages?(state) == false
    end

    test "returns true for active: :once with count > 0" do
      state = %State{active: :once, active_count: 1}
      assert State.should_deliver_messages?(state) == true
    end

    test "returns false for active: :once with count = 0" do
      state = %State{active: :once, active_count: 0}
      assert State.should_deliver_messages?(state) == false
    end

    test "returns true for integer mode with count > 0" do
      state = %State{active: 5, active_count: 5}
      assert State.should_deliver_messages?(state) == true
    end

    test "returns true for integer mode with count = 1" do
      state = %State{active: 10, active_count: 1}
      assert State.should_deliver_messages?(state) == true
    end

    test "returns false for integer mode with count = 0" do
      state = %State{active: 5, active_count: 0}
      assert State.should_deliver_messages?(state) == false
    end

    test "returns true for large count" do
      state = %State{active: 1000, active_count: 999}
      assert State.should_deliver_messages?(state) == true
    end
  end

  describe "active/passive mode integration" do
    test "complete cycle: true -> :once -> false" do
      # Start active
      state = %State{active: true, active_count: :infinity}
      assert State.should_deliver_messages?(state) == true

      # Switch to :once
      state = State.set_active(state, :once)
      assert State.should_deliver_messages?(state) == true
      assert state.active_count == 1

      # Deliver one message (decrement)
      state = State.decrement_active_count(state)
      assert State.should_deliver_messages?(state) == false
      assert state.active == false
    end

    test "complete cycle: false -> 3 -> 2 -> 1 -> false" do
      # Start passive
      state = %State{active: false, active_count: 0}
      assert State.should_deliver_messages?(state) == false

      # Switch to {active, 3}
      state = State.set_active(state, 3)
      assert State.should_deliver_messages?(state) == true
      assert state.active_count == 3

      # Deliver 3 messages
      state = State.decrement_active_count(state)
      assert state.active_count == 2
      assert State.should_deliver_messages?(state) == true

      state = State.decrement_active_count(state)
      assert state.active_count == 1
      assert State.should_deliver_messages?(state) == true

      state = State.decrement_active_count(state)
      assert state.active_count == 0
      assert State.should_deliver_messages?(state) == false
      assert state.active == false
    end

    test "switching modes resets count" do
      # Start with {active, 5}
      state = %State{active: 5, active_count: 5}

      # Decrement twice
      state = State.decrement_active_count(state)
      state = State.decrement_active_count(state)
      assert state.active_count == 3

      # Switch to :once (resets count to 1)
      state = State.set_active(state, :once)
      assert state.active_count == 1

      # Switch to {active, 10} (resets count to 10)
      state = State.set_active(state, 10)
      assert state.active_count == 10
    end
  end
end
