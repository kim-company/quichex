defmodule Quichex.Native.ConfigTest do
  use ExUnit.Case, async: true

  alias Quichex.Native
  import Quichex.Native.TestHelpers

  describe "transport tuning" do
    test "configures advanced knobs" do
      config = create_config()

      config
      |> Native.config_discover_pmtu(true)
      |> Native.config_log_keys()
      |> Native.config_enable_early_data()
      |> Native.config_set_max_amplification_factor(32)
      |> Native.config_set_ack_delay_exponent(5)
      |> Native.config_set_max_ack_delay(25)
      |> Native.config_set_initial_congestion_window_packets(10)
      |> Native.config_enable_hystart(true)
      |> Native.config_enable_pacing(true)
      |> Native.config_set_max_pacing_rate(1_000_000)
      |> Native.config_set_max_connection_window(4_000_000)
      |> Native.config_set_max_stream_window(1_000_000)
      |> Native.config_set_active_connection_id_limit(8)
      |> Native.config_set_disable_dcid_reuse(true)
      |> Native.config_grease(true)
      |> Native.config_enable_dgram(true, 64, 64)
      |> Native.config_set_cc_algorithm("reno")
      |> Native.config_set_ticket_key(:crypto.strong_rand_bytes(48))
    end

    test "validates stateless reset token length" do
      config = create_config()

      assert_raise Quichex.Native.ConfigError,
                   "config_set_stateless_reset_token failed: Stateless reset token must be 16 bytes",
                   fn ->
                     Native.config_set_stateless_reset_token(config, <<1, 2, 3>>)
                   end

      token = :crypto.strong_rand_bytes(16)
      assert is_reference(Native.config_set_stateless_reset_token(config, token))
    end
  end
end
