defmodule Quichex.HandlerExecutorTest do
  use ExUnit.Case, async: true

  alias Quichex.HandlerExecutor

  defmodule MockHandler do
    def callback(arg1, arg2, state) do
      send(state, {:callback, arg1, arg2})
      {:ok, {:handled, arg1, arg2}}
    end
  end

  defmodule SlowHandler do
    def sleepy(state) do
      send(state, :slow_started)
      Process.sleep(:infinity)
      {:ok, :never_reached}
    end
  end

  describe "submit/1" do
    test "executes handler function and returns result to connection" do
      {:ok, job_ref} =
        HandlerExecutor.submit(%{
          conn_pid: self(),
          handler_module: MockHandler,
          callback: :callback,
          args: [:foo, :bar],
          handler_state: self()
        })

      assert_receive {:callback, :foo, :bar}, 1000
      assert_receive {:handler_result, ^job_ref, {:ok, {:handled, :foo, :bar}}}, 1000
    end
  end

  describe "cancel_jobs/1" do
    test "terminates running jobs for a connection" do
      {:ok, job_ref} =
        HandlerExecutor.submit(%{
          conn_pid: self(),
          handler_module: SlowHandler,
          callback: :sleepy,
          args: [],
          handler_state: self()
        })

      assert_receive :slow_started, 500
      HandlerExecutor.cancel_jobs(self())

      assert_receive {:handler_result, ^job_ref, {:error, {:exit, :shutdown}}}, 1000
    end
  end
end
