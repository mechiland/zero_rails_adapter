# frozen_string_literal: true

require "rails"
require "action_controller/railtie"
require "zero_rails_adapter"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "zero-rails-adapter-test-secret"
    config.hosts.clear
    config.logger = Logger.new(nil)

    routes.append do
      mount ZeroRailsAdapter::Engine => "/zero"
    end
  end
end
