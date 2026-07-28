# frozen_string_literal: true

require "rails/generators"

module ZeroRailsAdapter
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def copy_initializer
        template "initializer.rb", "config/initializers/zero_rails_adapter.rb"
      end
    end
  end
end
