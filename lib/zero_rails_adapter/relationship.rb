# frozen_string_literal: true

module ZeroRailsAdapter
  class Relationship
    Hop = Struct.new(
      :source_fields,
      :destination,
      :destination_fields,
      keyword_init: true
    )

    attr_reader :source, :name, :kind, :hops

    def self.from_definition(definition, published_schema:)
      unless definition.respond_to?(:to_h)
        raise InvalidRelationshipError, "Relationship definition must be an object"
      end

      attributes = definition.to_h.symbolize_keys
      hop_definitions = if attributes.key?(:through)
        Array(attributes[:through])
      else
        [{
          source_fields: attributes[:source_fields],
          destination: attributes[:destination],
          destination_fields: attributes[:destination_fields]
        }]
      end

      new(
        source: attributes[:source],
        name: attributes[:name],
        kind: attributes[:kind],
        hops: hop_definitions,
        published_schema:
      )
    end

    def initialize(source:, name:, kind:, hops:, published_schema:)
      @source = source
      @name = name.to_s
      @kind = kind.to_s
      @published_schema = published_schema

      validate_header!
      @hops = validate_hops!(hops).freeze
    end

    private

    def validate_header!
      unless @published_schema.models.include?(source)
        raise InvalidRelationshipError,
          "Relationship source #{model_label(source)} is not published"
      end
      if name.empty?
        raise InvalidRelationshipError, "Relationship name must not be empty"
      end
      unless %w[one many].include?(kind)
        raise InvalidRelationshipError,
          "Relationship #{name} kind must be one or many"
      end
    end

    def validate_hops!(definitions)
      definitions = Array(definitions)
      if definitions.empty?
        raise InvalidRelationshipError,
          "Relationship #{name} must define at least one hop"
      end
      if definitions.length > 2
        raise InvalidRelationshipError,
          "Relationship #{name} supports at most two hops"
      end

      current_source = source
      definitions.map do |definition|
        unless definition.respond_to?(:to_h)
          raise InvalidRelationshipError,
            "Relationship #{name} hop must be an object"
        end

        attributes = definition.to_h.symbolize_keys
        source_fields = normalize_fields(attributes[:source_fields])
        destination = attributes[:destination]
        destination_fields = normalize_fields(attributes[:destination_fields])

        validate_model!(destination)
        validate_fields!(current_source, source_fields, "source")
        validate_fields!(destination, destination_fields, "destination")
        if source_fields.length != destination_fields.length
          raise InvalidRelationshipError,
            "Relationship #{name} hop fields must have matching arity"
        end

        current_source = destination
        Hop.new(source_fields:, destination:, destination_fields:).freeze
      end
    end

    def validate_model!(model)
      return if @published_schema.models.include?(model)

      raise InvalidRelationshipError,
        "Relationship #{name} destination #{model_label(model)} is not published"
    end

    def validate_fields!(model, fields, side)
      if fields.empty?
        raise InvalidRelationshipError,
          "Relationship #{name} #{side} fields must not be empty"
      end

      missing = fields - @published_schema.column_names_for(model)
      return if missing.empty?

      raise InvalidRelationshipError,
        "Relationship #{name} #{side} field #{missing.first} is not published"
    end

    def normalize_fields(value)
      Array(value).compact.map(&:to_s)
    end

    def model_label(model)
      model.respond_to?(:name) && model.name.present? ? model.name : model.inspect
    end
  end
end
