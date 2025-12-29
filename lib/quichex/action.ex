defmodule Quichex.Action do
  @moduledoc """
  Actions returned by the pure state machine to be executed by the runtime layer.

  The state machine is a pure functional core that processes events and returns
  a tuple of `{new_state, [actions]}`. The runtime layer (gen_statem) is responsible
  for executing these actions (side effects like sending UDP packets, messages, etc.).

  This separation keeps the state machine testable and the runtime simple.
  """

  @type stream_id :: non_neg_integer()
  @type milliseconds :: non_neg_integer()
  @type stream_type :: :bidirectional | :unidirectional

  @type t ::
          {:send_packets, [{binary(), send_info()}]}
          | {:schedule_timeout, milliseconds()}
          | {:close_stream, stream_id()}
          | {:spawn_stream_worker, stream_id(), stream_type()}
          | {:reply, GenServer.from(), term()}
          | {:stop, reason :: term()}

  @type send_info :: %{
          to: {tuple(), non_neg_integer()},
          from: {tuple(), non_neg_integer()}
        }

  @doc """
  Executes a single action.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec execute(t(), map()) :: :ok | {:error, term()}
  def execute({:send_packets, packets}, %{socket: socket}) do
    Enum.each(packets, fn {packet, send_info} ->
      {to_ip, to_port} = send_info.to
      :gen_udp.send(socket, to_ip, to_port, packet)
    end)

    :ok
  end

  def execute({:schedule_timeout, timeout_ms}, _context) when is_integer(timeout_ms) do
    Process.send_after(self(), :quic_timeout, timeout_ms)
    :ok
  end

  def execute({:close_stream, _stream_id}, %{conn_resource: _conn_resource}) do
    # TODO: Implement stream shutdown
    # Native.connection_stream_shutdown(conn_resource, stream_id, "both", 0)
    :ok
  end

  def execute({:spawn_stream_worker, _stream_id, _type}, _context) do
    # TODO: Implement stream worker spawning
    # Will be implemented in Phase 3
    :ok
  end

  def execute({:reply, from, response}, _context) do
    :gen_statem.reply(from, response)
    :ok
  end

  def execute({:stop, _reason}, _context) do
    # This action signals the state machine should stop
    # The caller will handle the actual termination
    :ok
  end

  @doc """
  Executes a list of actions in order.

  Returns `:ok` if all actions succeed.
  """
  @spec execute_all([t()], map()) :: :ok
  def execute_all(actions, context) when is_list(actions) do
    Enum.each(actions, fn action ->
      execute(action, context)
    end)
    :ok
  end
end
