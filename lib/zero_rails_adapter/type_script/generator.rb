# frozen_string_literal: true

module ZeroRailsAdapter
  module TypeScript
    class Generator
      SCHEMA_TYPES = {
        string: "string()",
        text: "string()",
        uuid: "string()",
        integer: "number()",
        bigint: "number()",
        float: "number()",
        decimal: "number()",
        boolean: "boolean()",
        date: "number()",
        datetime: "number()",
        timestamp: "number()",
        time: "number()",
        json: "json()",
        jsonb: "json()"
      }.freeze

      ZOD_TYPES = {
        string: "z.string()",
        text: "z.string()",
        uuid: "z.string().uuid()",
        integer: "z.number()",
        bigint: "z.number()",
        float: "z.number()",
        decimal: "z.number()",
        boolean: "z.boolean()",
        date: "z.number()",
        datetime: "z.number()",
        timestamp: "z.number()",
        time: "z.number()",
        json: "z.json()",
        jsonb: "z.json()"
      }.freeze

      attr_reader :models

      def initialize(models: nil)
        @models = Array(models || ZeroRailsAdapter.configuration.model_provider.call)
          .select { |model| active_record_model?(model) }
          .uniq
          .sort_by(&:table_name)
      end

      def schema
        sections = [
          "import {#{schema_imports.join(', ')}} from '@rocicorp/zero'",
          table_definitions,
          relationship_definitions,
          schema_export
        ]

        sections.reject(&:empty?).join("\n\n") << "\n"
      end

      def mutators
        sections = [
          "import {defineMutator, defineMutators} from '@rocicorp/zero'\nimport {z} from 'zod'",
          argument_schemas,
          mutator_export
        ]

        sections.reject(&:empty?).join("\n\n") << "\n"
      end

      private

      def active_record_model?(model)
        model.is_a?(Class) && model < ActiveRecord::Base && !model.abstract_class?
      end

      def table_definitions
        models.map do |model|
          columns = model.columns.map do |column|
            "    #{property_name(column.name)}: #{zero_type(model, column)},"
          end.join("\n")
          keys = primary_keys(model).map { |key| quote(key) }.join(", ")

          <<~TYPESCRIPT.chomp
            const #{variable_name(model)} = table(#{quote(model.table_name)})
              .columns({
            #{columns}
              })
              .primaryKey(#{keys})
          TYPESCRIPT
        end.join("\n\n")
      end

      def relationship_definitions
        relationships.group_by(&:first).map do |model, definitions|
          kinds = definitions.map do |_source, reflection, _destination|
            reflection.collection? ? "many" : "one"
          end.uniq.sort.join(", ")
          entries = definitions.map do |_source, reflection, destination|
            source_fields, destination_fields =
              relationship_fields(model, reflection, destination)
            kind = reflection.collection? ? "many" : "one"

            [
              "#{property_name(reflection.name)}: #{kind}({",
              "  sourceField: [#{source_fields.map { |field| quote(field) }.join(', ')}],",
              "  destSchema: #{variable_name(destination)},",
              "  destField: [#{destination_fields.map { |field| quote(field) }.join(', ')}],",
              "}),"
            ].join("\n")
          end.join("\n")

          [
            "const #{relationship_variable_name(model)} = relationships(#{variable_name(model)}, ({#{kinds}}) => ({",
            indent(entries, 2),
            "}))"
          ].join("\n")
        end.join("\n\n")
      end

      def schema_export
        table_vars = models.map { |model| variable_name(model) }.join(", ")
        relation_vars = relationships.map(&:first).uniq.map do |model|
          relationship_variable_name(model)
        end.join(", ")

        lines = ["export const schema = createSchema({", "  tables: [#{table_vars}],"]
        lines << "  relationships: [#{relation_vars}]," unless relation_vars.empty?
        lines.concat([
          "})",
          "",
          "export type Schema = typeof schema",
          "",
          "declare module '@rocicorp/zero' {",
          "  interface DefaultTypes {",
          "    schema: Schema",
          "  }",
          "}"
        ])
        lines.join("\n")
      end

      def argument_schemas
        models.flat_map do |model|
          [
            zod_schema(model, :create),
            zod_schema(model, :update),
            zod_schema(model, :destroy)
          ]
        end.join("\n\n")
      end

      def zod_schema(model, action)
        columns = mutation_columns(model, action).map do |column|
          "  #{property_name(column.name)}: #{zod_type(model, column, action)},"
        end.join("\n")

        <<~TYPESCRIPT.chomp
          const #{variable_name(model)}#{action.to_s.camelize}Args = z.object({
          #{columns}
          })
        TYPESCRIPT
      end

      def mutator_export
        tables = models.map do |model|
          variable = variable_name(model)
          table = property_name(model.table_name)
          create_values = create_insert_values(model)
          update_values = update_insert_values(model)

          [
            "#{table}: {",
            "  create: defineMutator(#{variable}CreateArgs, async ({tx, args}) => {",
            "    const now = Date.now()",
            "    await tx.mutate.#{table}.insert(#{create_values})",
            "  }),",
            "  update: defineMutator(#{variable}UpdateArgs, async ({tx, args}) => {",
            "    await tx.mutate.#{table}.update(#{update_values})",
            "  }),",
            "  destroy: defineMutator(#{variable}DestroyArgs, async ({tx, args}) => {",
            "    await tx.mutate.#{table}.delete(args)",
            "  }),",
            "},"
          ].join("\n")
        end.join("\n")

        [
          "export const mutators = defineMutators({",
          indent(tables, 2),
          "})"
        ].join("\n")
      end

      def create_insert_values(model)
        additions = []
        additions << "created_at: now" if model.column_names.include?("created_at")
        additions << "updated_at: now" if model.column_names.include?("updated_at")
        defaulted_columns(model).each do |column|
          value = if generated_attribute_names(model, :create).include?(column.name)
            "args.#{property_name(column.name)} ?? #{typescript_default(column)}"
          else
            typescript_default(column)
          end
          additions << "#{property_name(column.name)}: #{value}"
        end
        object_with_additions(additions)
      end

      def update_insert_values(model)
        additions = []
        additions << "updated_at: Date.now()" if model.column_names.include?("updated_at")
        object_with_additions(additions)
      end

      def object_with_additions(additions)
        return "args" if additions.empty?

        "{...args, #{additions.join(', ')}}"
      end

      def mutation_columns(model, action)
        primary = primary_keys(model)
        case action
        when :create
          allowed = generated_attribute_names(model, action)
          model.columns.select do |column|
            !timestamp_column?(column) &&
              (primary.include?(column.name) || allowed.include?(column.name))
          end
        when :update
          allowed = generated_attribute_names(model, action)
          model.columns.select do |column|
            primary.include?(column.name) ||
              (!timestamp_column?(column) && allowed.include?(column.name))
          end
        when :destroy
          model.columns.select { |column| primary.include?(column.name) }
        end
      end

      def generated_attribute_names(model, action)
        Array(
          ZeroRailsAdapter.configuration.generated_attributes.call(model, action)
        ).map(&:to_s)
      end

      def timestamp_column?(column)
        %w[created_at updated_at].include?(column.name)
      end

      def defaulted_columns(model)
        primary = primary_keys(model)
        model.columns.select do |column|
          !primary.include?(column.name) &&
            !timestamp_column?(column) &&
            !column.null &&
            !column.default.nil?
        end
      end

      def zero_type(model, column)
        if column.respond_to?(:array) && column.array
          type = "json<readonly #{typescript_scalar(column)}[]>()"
          return column.null ? "#{type}.optional()" : type
        end

        type = enum_values(model, column)&.then do |values|
          "enumeration<#{values.map { |value| quote(value) }.join(' | ')}>()"
        end
        type ||= mapped_type(SCHEMA_TYPES, model, column)
        type += ".optional()" if column.null
        type
      end

      def zod_type(model, column, action)
        values = enum_values(model, column)
        type = if column.respond_to?(:array) && column.array
          "z.array(#{mapped_type(ZOD_TYPES, model, column)})"
        elsif values
          "z.enum([#{values.map { |value| quote(value) }.join(', ')}])"
        else
          mapped_type(ZOD_TYPES, model, column)
        end

        if column.null
          "#{type}.nullish()"
        elsif action == :update && !primary_keys(model).include?(column.name)
          "#{type}.optional()"
        elsif action == :create && !column.default.nil?
          "#{type}.optional()"
        else
          type
        end
      end

      def mapped_type(mapping, model, column)
        mapping.fetch(column.type.to_sym) do
          raise UnsupportedColumnTypeError,
            "Cannot generate Zero TypeScript for #{model.name}.#{column.name} (#{column.type})"
        end
      end

      def enum_values(model, column)
        definition = model.defined_enums[column.name]
        definition&.keys
      end

      def schema_imports
        imports = %w[createSchema table]
        imports << "relationships" if relationships.any?
        imports << "enumeration" if models.any? { |model| model.defined_enums.any? }
        models.each do |model|
          model.columns.each do |column|
            imports << if enum_values(model, column)
              "enumeration"
            elsif column.respond_to?(:array) && column.array
              "json"
            else
              mapped_type(SCHEMA_TYPES, model, column).delete_suffix("()")
            end
          end
        end
        imports.uniq.sort
      end

      def typescript_scalar(column)
        case column.type.to_sym
        when :string, :text, :uuid then "string"
        when :integer, :bigint, :float, :decimal, :date, :datetime, :timestamp, :time
          "number"
        when :boolean then "boolean"
        else "unknown"
        end
      end

      def relationships
        @relationships ||= models.flat_map do |model|
          model.reflect_on_all_associations.filter_map do |reflection|
            next if reflection.polymorphic? || reflection.options[:through]

            destination = reflection.klass
            [model, reflection, destination] if models.include?(destination)
          rescue NameError
            nil
          end
        end
      end

      def relationship_fields(model, reflection, destination)
        if reflection.belongs_to?
          [
            Array(reflection.foreign_key).map(&:to_s),
            association_primary_keys(reflection, destination)
          ]
        else
          [
            association_primary_keys(reflection, model),
            Array(reflection.foreign_key).map(&:to_s)
          ]
        end
      end

      def association_primary_keys(reflection, model)
        configured = reflection.options[:primary_key]
        Array(configured || model.primary_key).map(&:to_s)
      end

      def primary_keys(model)
        keys = Array(model.primary_key).compact.map(&:to_s)
        return keys if keys.any?

        raise UnsupportedColumnTypeError, "#{model.name} has no primary key"
      end

      def relationship_variable_name(model)
        "#{variable_name(model)}Relationships"
      end

      def variable_name(model)
        model.table_name.gsub(/[^a-zA-Z0-9_]/, "_").camelize(:lower)
      end

      def property_name(value)
        string = value.to_s
        string.match?(/\A[$A-Z_a-z][$\w]*\z/) ? string : quote(string)
      end

      def quote(value)
        "'#{value.to_s.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")}'"
      end

      def typescript_literal(value)
        case value
        when String then quote(value)
        when Numeric then value.to_s
        when true then "true"
        when false then "false"
        else
          raise UnsupportedColumnTypeError, "Cannot serialize database default #{value.inspect}"
        end
      end

      def typescript_default(column)
        value = column.default
        case column.type.to_sym
        when :boolean
          ActiveModel::Type::Boolean.new.cast(value) ? "true" : "false"
        when :integer, :bigint, :float, :decimal
          value.to_s
        else
          typescript_literal(value)
        end
      end

      def indent(value, spaces)
        prefix = " " * spaces
        value.lines.map { |line| "#{prefix}#{line}" }.join.chomp
      end
    end
  end
end
