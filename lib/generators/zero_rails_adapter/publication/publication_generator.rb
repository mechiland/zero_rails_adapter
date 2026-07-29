# frozen_string_literal: true

require "rails/generators"
require "zero_rails_adapter"

module ZeroRailsAdapter
  module Generators
    class PublicationGenerator < Rails::Generators::Base
      argument :publication_name,
        type: :string,
        default: ZeroRailsAdapter::PostgreSQL::PublicationGenerator::DEFAULT_NAME

      def create_publication_sql
        sql = ZeroRailsAdapter::PostgreSQL::PublicationGenerator.new(
          name: publication_name
        ).sql
        create_file "db/zero_publication.sql", sql
      end
    end
  end
end
