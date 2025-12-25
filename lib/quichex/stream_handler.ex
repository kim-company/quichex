defmodule Quichex.StreamHandler do
  @moduledoc """
  GenServer that wraps a user's StreamHandler.Behaviour implementation.

  This module provides the process infrastructure for handling QUIC streams,
  calling the user's behavior callbacks and executing returned actions.

  ## Architecture

  - One StreamHandler process per stream
  - Wraps user's behavior module (implements Quichex.StreamHandler.Behaviour)
  - Handles I/O via NIFs (connection_stream_send)
  - Executes actions returned by user callbacks
  - Supervised under StreamHandlerSupervisor (one per connection)

  ## Differences from StreamWorker

  StreamWorker (Phase 3):
  - Only handled I/O for large transfers (>= 64KB)
  - No user code execution
  - Simple send/recv operations

  StreamHandler (current):
  - Wraps user behavior module
  - Handles ALL stream types (configurable)
  - Rich action system (send, notify, close)
  - Can block (runs in own process)

  ## Lifecycle

  1. Spawned by Connection when stream is opened/received
  2. Calls user's `init/4` callback
  3. Receives `{:stream_data, data, fin}` casts from Connection
  4. Calls user's `handle_data/3` callback
  5. Executes actions returned by user
  6. Terminates when stream closes or crashes
  """

  use GenServer
  require Logger

  alias Quichex.Native

  defstruct [
    :conn_resource,
    :conn_pid,
    :stream_id,
    :direction,
    :stream_type,
    :user_module,
    :user_state,
    fin_received: false,
    fin_sent: false,
    bytes_sent: 0,
    bytes_received: 0
  ]

  @type t :: %__MODULE__{
          conn_resource: reference(),
          conn_pid: pid(),
          stream_id: non_neg_integer(),
          direction: :incoming | :outgoing,
          stream_type: :bidirectional | :unidirectional,
          user_module: module(),
          user_state: term(),
          fin_received: boolean(),
          fin_sent: boolean(),
          bytes_sent: non_neg_integer(),
          bytes_received: non_neg_integer()
        }

  ## Public API

  @doc """
  Starts a stream handler process.

  ## Options

    * `:conn_resource` - NIF resource for the QUIC connection (required)
    * `:conn_pid` - PID of parent connection process (required)
    * `:stream_id` - Stream ID this handler manages (required)
    * `:direction` - `:incoming` or `:outgoing` (required)
    * `:stream_type` - `:bidirectional` or `:unidirectional` (required)
    * `:handler_module` - User's behavior module (required)
    * `:handler_opts` - Options passed to user's init (default: [])

  ## Example

      {:ok, pid} = Quichex.StreamHandler.start_link(
        conn_resource: conn_resource,
        conn_pid: self(),
        stream_id: 0,
        direction: :outgoing,
        stream_type: :bidirectional,
        handler_module: MyApp.EchoHandler,
        handler_opts: []
      )
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Synchronously sends data on the stream.

  This is used internally when user's callback returns `{:send, data}` action.
  Can also be called directly for imperative sends.
  """
  @spec send_data(pid(), binary(), boolean()) :: :ok | {:error, term()}
  def send_data(handler_pid, data, fin \\ false) when is_binary(data) and is_boolean(fin) do
    GenServer.call(handler_pid, {:send, data, fin})
  end

  @doc """
  Shuts down the stream in the specified direction.

  ## Arguments

    * `handler_pid` - StreamHandler process ID
    * `direction` - `:read`, `:write`, or `:both`
    * `opts` - Options (keyword list)

  ## Options

    * `:error_code` - QUIC error code (default: 0)

  ## Returns

    * `:ok` - Success
    * `{:error, reason}` - On failure
  """
  @spec shutdown(pid(), :read | :write | :both, keyword()) :: :ok | {:error, term()}
  def shutdown(handler_pid, direction, opts \\ []) when direction in [:read, :write, :both] do
    GenServer.call(handler_pid, {:shutdown, direction, opts})
  end

  @doc """
  Gets the stream ID for this handler.
  """
  @spec stream_id(pid()) :: non_neg_integer()
  def stream_id(handler_pid) do
    GenServer.call(handler_pid, :stream_id)
  end

  @doc """
  Gets handler statistics.
  """
  @spec stats(pid()) :: {:ok, map()} | {:error, term()}
  def stats(handler_pid) do
    GenServer.call(handler_pid, :stats)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    conn_resource = Keyword.fetch!(opts, :conn_resource)
    conn_pid = Keyword.fetch!(opts, :conn_pid)
    stream_id = Keyword.fetch!(opts, :stream_id)
    direction = Keyword.fetch!(opts, :direction)
    stream_type = Keyword.fetch!(opts, :stream_type)
    user_module = Keyword.fetch!(opts, :handler_module)
    user_opts = Keyword.get(opts, :handler_opts, [])

    # Verify user module implements behavior
    unless implements_behaviour?(user_module, Quichex.StreamHandler.Behaviour) do
      Logger.error(
        "Module #{inspect(user_module)} does not implement Quichex.StreamHandler.Behaviour"
      )

      {:stop, {:invalid_handler, user_module}}
    end

    # Call user's init callback
    case user_module.init(stream_id, direction, stream_type, user_opts) do
      {:ok, user_state} ->
        state = %__MODULE__{
          conn_resource: conn_resource,
          conn_pid: conn_pid,
          stream_id: stream_id,
          direction: direction,
          stream_type: stream_type,
          user_module: user_module,
          user_state: user_state
        }

        Logger.debug(
          "StreamHandler started: stream=#{stream_id}, direction=#{direction}, type=#{stream_type}, module=#{inspect(user_module)}"
        )

        {:ok, state}

      {:stop, reason} ->
        Logger.debug(
          "StreamHandler init rejected stream #{stream_id}: #{inspect(reason)}"
        )

        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:stream_data, data, fin}, state) do
    state = %{state | bytes_received: state.bytes_received + byte_size(data)}

    # Call user's handle_data callback
    case state.user_module.handle_data(data, fin, state.user_state) do
      {:ok, new_user_state} ->
        new_state = %{state | user_state: new_user_state, fin_received: fin}
        {:noreply, new_state}

      {:ok, actions, new_user_state} ->
        # Execute actions
        case execute_actions(actions, state) do
          :ok ->
            new_state = %{state | user_state: new_user_state, fin_received: fin}
            {:noreply, new_state}

          {:error, reason} ->
            Logger.error(
              "StreamHandler #{state.stream_id} action execution failed: #{inspect(reason)}"
            )

            {:stop, {:action_error, reason}, state}
        end

      {:stop, reason, new_user_state} ->
        Logger.debug("StreamHandler #{state.stream_id} stopped: #{inspect(reason)}")
        {:stop, reason, %{state | user_state: new_user_state}}
    end
  end

  @impl true
  def handle_call({:send, data, fin}, _from, state) do
    if state.fin_sent do
      {:reply, {:error, :stream_already_finished}, state}
    else
      case do_send(state, data, fin) do
        {:ok, new_state} ->
          {:reply, :ok, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:shutdown, direction, opts}, _from, state) do
    error_code = Keyword.get(opts, :error_code, 0)

    case Quichex.Connection.stream_shutdown(state.conn_pid, state.stream_id, direction, error_code: error_code) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stream_id, _from, state) do
    {:reply, state.stream_id, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      stream_id: state.stream_id,
      direction: state.direction,
      stream_type: state.stream_type,
      bytes_sent: state.bytes_sent,
      bytes_received: state.bytes_received,
      fin_sent: state.fin_sent,
      fin_received: state.fin_received
    }

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def terminate(reason, state) do
    # Call user's callbacks
    if reason == :normal or reason == :shutdown do
      state.user_module.handle_stream_closed(:normal, state.user_state)
    else
      state.user_module.handle_stream_closed({:error, reason}, state.user_state)
    end

    state.user_module.terminate(reason, state.user_state)

    Logger.debug(
      "StreamHandler #{state.stream_id} terminated: #{inspect(reason)}"
    )

    :ok
  end

  ## Private Functions

  defp do_send(state, data, fin) do
    # Call NIF to write data to stream buffers
    case Native.connection_stream_send(state.conn_resource, state.stream_id, data, fin) do
      {:ok, bytes_written} ->
        # Notify connection that we wrote data (connection will generate packets)
        send(state.conn_pid, {:stream_handler_sent, state.stream_id, bytes_written})

        new_state = %{
          state
          | bytes_sent: state.bytes_sent + bytes_written,
            fin_sent: fin
        }

        {:ok, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_actions(actions, state) when is_list(actions) do
    Enum.reduce_while(actions, :ok, fn action, _acc ->
      case execute_action(action, state) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp execute_action({:send, data}, state) when is_binary(data) do
    case do_send(state, data, false) do
      {:ok, _new_state} -> :ok
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  defp execute_action({:send, data, fin}, state) when is_binary(data) and is_boolean(fin) do
    case do_send(state, data, fin) do
      {:ok, _new_state} -> :ok
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  defp execute_action({:close, error_code}, _state) when is_integer(error_code) do
    # TODO: Implement stream close with error code via NIF
    Logger.debug("TODO: Stream close with error code #{error_code} not yet implemented")
    :ok
  end

  defp execute_action({:notify, pid, message}, _state) when is_pid(pid) do
    send(pid, message)
    :ok
  end

  defp execute_action(unknown_action, _state) do
    Logger.warning("Unknown action: #{inspect(unknown_action)}")
    {:error, {:unknown_action, unknown_action}}
  end

  defp implements_behaviour?(module, behaviour) do
    try do
      behaviours = module.module_info(:attributes)[:behaviour] || []
      behaviour in behaviours
    rescue
      _ -> false
    end
  end
end
