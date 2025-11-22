defmodule Quichex.ConfigTest do
  use ExUnit.Case, async: true
  doctest Quichex.Config

  alias Quichex.Config

  describe "new/1" do
    test "creates a new config successfully" do
      assert {:ok, config} = Config.new()
      assert %Config{resource: resource} = config
      assert is_reference(resource)
    end

    test "new! creates a config successfully" do
      config = Config.new!()
      assert %Config{resource: resource} = config
      assert is_reference(resource)
    end
  end

  describe "set_application_protos/2" do
    test "sets application protocols" do
      config =
        Config.new!()
        |> Config.set_application_protos(["http/1.1", "http/0.9"])

      assert %Config{} = config
    end

    test "sets single protocol" do
      config =
        Config.new!()
        |> Config.set_application_protos(["myproto"])

      assert %Config{} = config
    end
  end

  describe "set_max_idle_timeout/2" do
    test "sets max idle timeout" do
      config =
        Config.new!()
        |> Config.set_max_idle_timeout(30_000)

      assert %Config{} = config
    end

    test "sets timeout to zero" do
      config =
        Config.new!()
        |> Config.set_max_idle_timeout(0)

      assert %Config{} = config
    end
  end

  describe "flow control settings" do
    test "sets initial max streams bidi" do
      config =
        Config.new!()
        |> Config.set_initial_max_streams_bidi(100)

      assert %Config{} = config
    end

    test "sets initial max streams uni" do
      config =
        Config.new!()
        |> Config.set_initial_max_streams_uni(100)

      assert %Config{} = config
    end

    test "sets initial max data" do
      config =
        Config.new!()
        |> Config.set_initial_max_data(10_000_000)

      assert %Config{} = config
    end

    test "sets initial max stream data bidi local" do
      config =
        Config.new!()
        |> Config.set_initial_max_stream_data_bidi_local(1_000_000)

      assert %Config{} = config
    end

    test "sets initial max stream data bidi remote" do
      config =
        Config.new!()
        |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)

      assert %Config{} = config
    end

    test "sets initial max stream data uni" do
      config =
        Config.new!()
        |> Config.set_initial_max_stream_data_uni(1_000_000)

      assert %Config{} = config
    end
  end

  describe "TLS settings" do
    test "sets verify peer to true" do
      config =
        Config.new!()
        |> Config.verify_peer(true)

      assert %Config{} = config
    end

    test "sets verify peer to false" do
      config =
        Config.new!()
        |> Config.verify_peer(false)

      assert %Config{} = config
    end
  end

  describe "congestion control" do
    test "sets reno algorithm" do
      config =
        Config.new!()
        |> Config.set_cc_algorithm(:reno)

      assert %Config{} = config
    end

    test "sets cubic algorithm" do
      config =
        Config.new!()
        |> Config.set_cc_algorithm(:cubic)

      assert %Config{} = config
    end

    test "sets bbr algorithm" do
      config =
        Config.new!()
        |> Config.set_cc_algorithm(:bbr)

      assert %Config{} = config
    end

    test "sets bbr2 algorithm" do
      config =
        Config.new!()
        |> Config.set_cc_algorithm(:bbr2)

      assert %Config{} = config
    end
  end

  describe "datagrams" do
    test "enables datagrams with default queue lengths" do
      config =
        Config.new!()
        |> Config.enable_dgram(true)

      assert %Config{} = config
    end

    test "enables datagrams with custom queue lengths" do
      config =
        Config.new!()
        |> Config.enable_dgram(true, recv_queue_len: 500, send_queue_len: 500)

      assert %Config{} = config
    end

    test "disables datagrams" do
      config =
        Config.new!()
        |> Config.enable_dgram(false)

      assert %Config{} = config
    end
  end

  describe "builder pattern" do
    test "chains multiple configuration calls" do
      config =
        Config.new!()
        |> Config.set_application_protos(["myproto"])
        |> Config.set_max_idle_timeout(30_000)
        |> Config.set_initial_max_streams_bidi(100)
        |> Config.set_initial_max_streams_uni(100)
        |> Config.set_initial_max_data(10_000_000)
        |> Config.set_initial_max_stream_data_bidi_local(1_000_000)
        |> Config.set_initial_max_stream_data_bidi_remote(1_000_000)
        |> Config.set_initial_max_stream_data_uni(1_000_000)
        |> Config.verify_peer(false)
        |> Config.set_cc_algorithm(:cubic)
        |> Config.enable_dgram(true, recv_queue_len: 1000, send_queue_len: 1000)

      assert %Config{resource: resource} = config
      assert is_reference(resource)
    end

    test "creates a typical client config" do
      config =
        Config.new!()
        |> Config.set_application_protos(["http/1.1"])
        |> Config.set_max_idle_timeout(30_000)
        |> Config.verify_peer(true)

      assert %Config{} = config
    end
  end
end
