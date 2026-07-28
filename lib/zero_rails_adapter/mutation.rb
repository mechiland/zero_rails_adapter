# frozen_string_literal: true

module ZeroRailsAdapter
  class Mutation
    REQUIRED_KEYS = %w[type id clientID name args timestamp].freeze

    attr_reader :type, :id, :client_id, :name, :args, :timestamp

    def self.parse(value)
      unless value.is_a?(Hash)
        raise ParseError, "Mutation must be an object"
      end

      missing = REQUIRED_KEYS.reject { |key| value.key?(key) }
      raise ParseError, "Mutation is missing #{missing.join(', ')}" if missing.any?
      raise ParseError, "Mutation type must be custom" unless value["type"] == "custom"
      raise ParseError, "Mutation id must be a number" unless value["id"].is_a?(Numeric)
      raise ParseError, "Mutation clientID must be a string" unless value["clientID"].is_a?(String)
      raise ParseError, "Mutation name must be a string" unless value["name"].is_a?(String)
      raise ParseError, "Mutation args must be an array" unless value["args"].is_a?(Array)
      raise ParseError, "Mutation timestamp must be a number" unless value["timestamp"].is_a?(Numeric)

      new(
        type: value["type"],
        id: value["id"],
        client_id: value["clientID"],
        name: value["name"],
        args: value["args"],
        timestamp: value["timestamp"]
      )
    end

    def initialize(type:, id:, client_id:, name:, args:, timestamp:)
      @type = type
      @id = id
      @client_id = client_id
      @name = name
      @args = args
      @timestamp = timestamp
    end

    def argument
      args.first
    end

    def identifier
      {"clientID" => client_id, "id" => id}
    end
  end
end
