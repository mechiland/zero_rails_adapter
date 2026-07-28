# frozen_string_literal: true

require "rails/generators"
require "zero_rails_adapter"

module ZeroRailsAdapter
  module Generators
    class TypeScriptGenerator < Rails::Generators::Base
      argument :destination, type: :string, default: "app/javascript/zero"

      def generate_typescript
        generator = ZeroRailsAdapter::TypeScript::Generator.new
        create_file File.join(destination, "schema.ts"), generator.schema
        create_file File.join(destination, "mutators.ts"), generator.mutators
      end
    end
  end
end
