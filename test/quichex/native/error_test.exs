defmodule Quichex.Native.ErrorTest do
  use ExUnit.Case, async: true
  doctest Quichex.Native.Error

  alias Quichex.Native.Error

  describe "exception/1" do
    test "creates a structured error with operation and reason" do
      error = Error.exception(operation: :config_new, reason: "Invalid version")

      assert %Error{} = error
      assert error.operation == :config_new
      assert error.reason == "Invalid version"
      assert error.message == "NIF operation :config_new failed: Invalid version"
    end

    test "creates error for different operations" do
      error = Error.exception(operation: :config_set_application_protos, reason: "Protocol too long")

      assert error.operation == :config_set_application_protos
      assert error.reason == "Protocol too long"
      assert error.message =~ ":config_set_application_protos"
    end
  end

  describe "message/1" do
    test "returns the formatted message" do
      error = Error.exception(operation: :config_load_cert_chain_from_pem_file, reason: "File not found")

      assert Error.message(error) == "NIF operation :config_load_cert_chain_from_pem_file failed: File not found"
    end
  end

  describe "integration with Config" do
    test "raises structured error when config operation fails" do
      # Test with invalid certificate file path
      config = Quichex.Config.new!()

      assert_raise Error, ~r/NIF operation :config_load_cert_chain_from_pem_file failed/, fn ->
        Quichex.Config.load_cert_chain_from_pem_file(config, "/nonexistent/path.pem")
      end
    end

    test "error contains operation and reason fields" do
      config = Quichex.Config.new!()

      try do
        Quichex.Config.load_priv_key_from_pem_file(config, "/invalid/key.pem")
      rescue
        e in Error ->
          assert e.operation == :config_load_priv_key_from_pem_file
          assert e.reason != nil
          assert is_binary(e.reason)
      end
    end
  end
end
