# frozen_string_literal: true

module ZeroRailsAdapter
  module PostgreSQL
    class PublicationGenerator
      DEFAULT_NAME = "zero_data"

      def initialize(name: DEFAULT_NAME, published_schema: nil)
        @name = name.to_s
        @published_schema = PublishedSchema.new(
          published_schema || ZeroRailsAdapter.configuration.published_schema.call
        )
      end

      def sql
        entries = @published_schema.models.map do |model|
          connection = model.connection
          quoted_columns = @published_schema.column_names_for(model).map do |column|
            connection.quote_column_name(column)
          end

          "#{connection.quote_table_name(model.table_name)} (#{quoted_columns.join(', ')})"
        end

        raise UnsafePublicationError, "Published schema must include at least one table" if entries.empty?

        connection = @published_schema.models.first.connection
        <<~SQL
          CREATE PUBLICATION #{connection.quote_column_name(@name)} FOR TABLE
            #{entries.join(",\n  ")};
        SQL
      end
    end
  end
end
