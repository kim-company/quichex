defmodule Quichex.Native.ConfigTest do
  use ExUnit.Case, async: true

  alias Quichex.Native
  import Quichex.Native.TestHelpers

  describe "transport tuning" do
    test "configures advanced knobs" do
      config = create_config()

      assert :ok = ok!(Native.config_discover_pmtu(config, true))
      assert :ok = ok!(Native.config_log_keys(config))
      assert :ok = ok!(Native.config_enable_early_data(config))
      assert :ok = ok!(Native.config_set_max_amplification_factor(config, 32))
      assert :ok = ok!(Native.config_set_ack_delay_exponent(config, 5))
      assert :ok = ok!(Native.config_set_max_ack_delay(config, 25))
      assert :ok = ok!(Native.config_set_initial_congestion_window_packets(config, 10))
      assert :ok = ok!(Native.config_enable_hystart(config, true))
      assert :ok = ok!(Native.config_enable_pacing(config, true))
      assert :ok = ok!(Native.config_set_max_pacing_rate(config, 1_000_000))
      assert :ok = ok!(Native.config_set_max_connection_window(config, 4_000_000))
      assert :ok = ok!(Native.config_set_max_stream_window(config, 1_000_000))
      assert :ok = ok!(Native.config_set_active_connection_id_limit(config, 8))
      assert :ok = ok!(Native.config_set_disable_dcid_reuse(config, true))
      assert :ok = ok!(Native.config_grease(config, true))
      assert :ok = ok!(Native.config_enable_dgram(config, true, 64, 64))
      assert :ok = ok!(Native.config_set_cc_algorithm(config, "reno"))
      assert :ok = ok!(Native.config_set_ticket_key(config, :crypto.strong_rand_bytes(48)))
    end

    test "validates stateless reset token length" do
      config = create_config()

      assert {:error, "Stateless reset token must be 16 bytes"} =
               Native.config_set_stateless_reset_token(config, <<1, 2, 3>>)

      token = :crypto.strong_rand_bytes(16)
      assert :ok = ok!(Native.config_set_stateless_reset_token(config, token))
    end
  end
end
