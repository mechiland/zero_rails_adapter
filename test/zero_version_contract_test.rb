# frozen_string_literal: true

require "test_helper"

class ZeroVersionContractTest < ZeroTestCase
  CONTRACT_PACKAGE = File.expand_path("contract/package.json", __dir__)
  CONTRACT_LOCK = File.expand_path("contract/package-lock.json", __dir__)
  LOCKED_ZERO_VERSION = "1.8.0"

  def test_contract_pins_the_client_and_zero_cache_cli_to_one_exact_version
    assert_path_exists CONTRACT_PACKAGE

    package = JSON.parse(File.read(CONTRACT_PACKAGE))
    assert_equal LOCKED_ZERO_VERSION,
      package.dig("dependencies", "@rocicorp/zero")
    assert_equal "zero-cache",
      package.dig("scripts", "zero-cache")

    lock = JSON.parse(File.read(CONTRACT_LOCK))
    assert_equal LOCKED_ZERO_VERSION,
      lock.dig("packages", "node_modules/@rocicorp/zero", "version")
  end
end
