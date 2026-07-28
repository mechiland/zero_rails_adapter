# frozen_string_literal: true

require "rails/generators"

module ZeroRailsAdapter
  module Generators
    class MutatorGenerator < Rails::Generators::Base
      argument :name, type: :string, banner: "namespace.action"

      source_root File.expand_path("templates", __dir__)

      def create_mutator
        template "mutator.rb", File.join("app/mutators", "#{file_path}_mutator.rb")
      end

      private

      def name_parts
        @name_parts ||= name.split(/[|.]/)
      end

      def class_name
        "#{name_parts.map(&:camelize).join('::')}Mutator"
      end

      def file_path
        name_parts.map(&:underscore).join("/")
      end
    end
  end
end
