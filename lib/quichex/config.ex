defmodule Quichex.Config do
  @moduledoc """
  Configuration for QUIC connections.

  Provides a builder pattern for ergonomic configuration of QUIC parameters.
  """

  alias Quichex.Native
  alias Quichex.Native.Error
  defstruct [:resource]
  @type t :: %__MODULE__{resource: reference()}
  @quic_version_1 0x0000_0001

  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts \\ []) do
    version = Keyword.get(opts, :version, @quic_version_1)
    case Native.config_new(version) do
      {:ok, resource} -> {:ok, %__MODULE__{resource: resource}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise Error, operation: :config_new, reason: reason
    end
  end

  @spec set_application_protos(t(), [String.t()]) :: t()
  def set_application_protos(%__MODULE__{resource: resource} = config, protos) when is_list(protos) do
    case Native.config_set_application_protos(resource, protos) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_application_protos, reason: reason
    end
  end

  @spec set_max_idle_timeout(t(), non_neg_integer()) :: t()
  def set_max_idle_timeout(%__MODULE__{resource: resource} = config, millis) when is_integer(millis) and millis >= 0 do
    case Native.config_set_max_idle_timeout(resource, millis) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_max_idle_timeout, reason: reason
    end
  end

  @spec set_initial_max_streams_bidi(t(), non_neg_integer()) :: t()
  def set_initial_max_streams_bidi(%__MODULE__{resource: resource} = config, v) when is_integer(v) and v >= 0 do
    case Native.config_set_initial_max_streams_bidi(resource, v) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_initial_max_streams_bidi, reason: reason
    end
  end

  @spec set_initial_max_streams_uni(t(), non_neg_integer()) :: t()
  def set_initial_max_streams_uni(%__MODULE__{resource: resource} = config, v) when is_integer(v) and v >= 0 do
    case Native.config_set_initial_max_streams_uni(resource, v) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_initial_max_streams_uni, reason: reason
    end
  end

  @spec set_initial_max_data(t(), non_neg_integer()) :: t()
  def set_initial_max_data(%__MODULE__{resource: resource} = config, v) when is_integer(v) and v >= 0 do
    case Native.config_set_initial_max_data(resource, v) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_initial_max_data, reason: reason
    end
  end

  @spec set_initial_max_stream_data_bidi_local(t(), non_neg_integer()) :: t()
  def set_initial_max_stream_data_bidi_local(%__MODULE__{resource: resource} = config, v) when is_integer(v) and v >= 0 do
    case Native.config_set_initial_max_stream_data_bidi_local(resource, v) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_initial_max_stream_data_bidi_local, reason: reason
    end
  end

  @spec set_initial_max_stream_data_bidi_remote(t(), non_neg_integer()) :: t()
  def set_initial_max_stream_data_bidi_remote(%__MODULE__{resource: resource} = config, v) when is_integer(v) and v >= 0 do
    case Native.config_set_initial_max_stream_data_bidi_remote(resource, v) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_initial_max_stream_data_bidi_remote, reason: reason
    end
  end

  @spec set_initial_max_stream_data_uni(t(), non_neg_integer()) :: t()
  def set_initial_max_stream_data_uni(%__MODULE__{resource: resource} = config, v) when is_integer(v) and v >= 0 do
    case Native.config_set_initial_max_stream_data_uni(resource, v) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_initial_max_stream_data_uni, reason: reason
    end
  end

  @spec verify_peer(t(), boolean()) :: t()
  def verify_peer(%__MODULE__{resource: resource} = config, verify) when is_boolean(verify) do
    case Native.config_verify_peer(resource, verify) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_verify_peer, reason: reason
    end
  end

  @spec load_cert_chain_from_pem_file(t(), String.t()) :: t()
  def load_cert_chain_from_pem_file(%__MODULE__{resource: resource} = config, path) when is_binary(path) do
    case Native.config_load_cert_chain_from_pem_file(resource, path) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_load_cert_chain_from_pem_file, reason: reason
    end
  end

  @spec load_priv_key_from_pem_file(t(), String.t()) :: t()
  def load_priv_key_from_pem_file(%__MODULE__{resource: resource} = config, path) when is_binary(path) do
    case Native.config_load_priv_key_from_pem_file(resource, path) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_load_priv_key_from_pem_file, reason: reason
    end
  end

  @spec load_verify_locations_from_file(t(), String.t()) :: t()
  def load_verify_locations_from_file(%__MODULE__{resource: resource} = config, path) when is_binary(path) do
    case Native.config_load_verify_locations_from_file(resource, path) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_load_verify_locations_from_file, reason: reason
    end
  end

  @spec set_cc_algorithm(t(), :reno | :cubic | :bbr | :bbr2) :: t()
  def set_cc_algorithm(%__MODULE__{resource: resource} = config, algo) when algo in [:reno, :cubic, :bbr, :bbr2] do
    algo_str = Atom.to_string(algo)
    case Native.config_set_cc_algorithm(resource, algo_str) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_cc_algorithm, reason: reason
    end
  end

  @spec enable_dgram(t(), boolean(), keyword()) :: t()
  def enable_dgram(%__MODULE__{resource: resource} = config, enabled, opts \\ []) when is_boolean(enabled) do
    recv_queue_len = Keyword.get(opts, :recv_queue_len, 1000)
    send_queue_len = Keyword.get(opts, :send_queue_len, 1000)
    case Native.config_enable_dgram(resource, enabled, recv_queue_len, send_queue_len) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_enable_dgram, reason: reason
    end
  end

  @doc """
  Sets the maximum UDP payload size for receiving packets.

  This is critical for proper QUIC operation, especially for TLS handshake.
  The recommended value is 1350 bytes to avoid IP fragmentation.

  ## Examples

      config
      |> Quichex.Config.set_max_recv_udp_payload_size(1350)

  """
  @spec set_max_recv_udp_payload_size(t(), pos_integer()) :: t()
  def set_max_recv_udp_payload_size(%__MODULE__{resource: resource} = config, size) when is_integer(size) and size > 0 do
    case Native.config_set_max_recv_udp_payload_size(resource, size) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_max_recv_udp_payload_size, reason: reason
    end
  end

  @doc """
  Sets the maximum UDP payload size for sending packets.

  This is critical for proper QUIC operation, especially for TLS handshake.
  The recommended value is 1350 bytes to avoid IP fragmentation.

  ## Examples

      config
      |> Quichex.Config.set_max_send_udp_payload_size(1350)

  """
  @spec set_max_send_udp_payload_size(t(), pos_integer()) :: t()
  def set_max_send_udp_payload_size(%__MODULE__{resource: resource} = config, size) when is_integer(size) and size > 0 do
    case Native.config_set_max_send_udp_payload_size(resource, size) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_max_send_udp_payload_size, reason: reason
    end
  end

  @doc """
  Disables or enables active connection migration.

  When disabled (true), the connection will not migrate to different network paths.
  This is recommended for initial implementations and simpler network scenarios.

  ## Examples

      config
      |> Quichex.Config.set_disable_active_migration(true)

  """
  @spec set_disable_active_migration(t(), boolean()) :: t()
  def set_disable_active_migration(%__MODULE__{resource: resource} = config, disable) when is_boolean(disable) do
    case Native.config_set_disable_active_migration(resource, disable) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_set_disable_active_migration, reason: reason
    end
  end

  @doc """
  Enables or disables GREASE.

  GREASE (Generate Random Extensions And Sustain Extensibility) helps test
  protocol extensibility by sending random values. Enabled by default in quiche.

  ## Examples

      config
      |> Quichex.Config.grease(true)

  """
  @spec grease(t(), boolean()) :: t()
  def grease(%__MODULE__{resource: resource} = config, enable) when is_boolean(enable) do
    case Native.config_grease(resource, enable) do
      {:ok, _} -> config
      {:error, reason} -> raise Error, operation: :config_grease, reason: reason
    end
  end
end
