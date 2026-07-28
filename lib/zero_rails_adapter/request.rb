# frozen_string_literal: true

module ZeroRailsAdapter
  class Request
    REQUIRED_KEYS = %w[clientGroupID mutations pushVersion timestamp requestID].freeze

    attr_reader :client_group_id, :mutations, :push_version, :timestamp,
      :request_id, :schema, :app_id, :body

    def self.parse(body, query:)
      body = body.to_h.stringify_keys if body.respond_to?(:to_h)
      query = query.to_h.stringify_keys if query.respond_to?(:to_h)
      mutation_ids = extract_mutation_ids(body)

      validate_body!(body, mutation_ids:)
      validate_query!(query, mutation_ids:)

      unless body["pushVersion"] == 1
        raise UnsupportedPushVersionError.new(body["pushVersion"], mutation_ids:)
      end

      mutations = body["mutations"].map { |value| Mutation.parse(value) }
      new(
        body:,
        client_group_id: body["clientGroupID"],
        mutations:,
        push_version: body["pushVersion"],
        timestamp: body["timestamp"],
        request_id: body["requestID"],
        schema: query["schema"],
        app_id: query["appID"]
      )
    rescue ParseError => error
      if error.mutation_ids.empty?
        raise ParseError.new(error.message, mutation_ids:, source: error.source)
      end

      raise
    end

    def self.validate_body!(body, mutation_ids:)
      raise ParseError.new("Push body must be an object", mutation_ids:) unless body.is_a?(Hash)

      missing = REQUIRED_KEYS.reject { |key| body.key?(key) }
      raise ParseError.new("Push body is missing #{missing.join(', ')}", mutation_ids:) if missing.any?
      raise ParseError.new("clientGroupID must be a string", mutation_ids:) unless body["clientGroupID"].is_a?(String)
      raise ParseError.new("mutations must be an array", mutation_ids:) unless body["mutations"].is_a?(Array)
      raise ParseError.new("pushVersion must be a number", mutation_ids:) unless body["pushVersion"].is_a?(Numeric)
      raise ParseError.new("timestamp must be a number", mutation_ids:) unless body["timestamp"].is_a?(Numeric)
      raise ParseError.new("requestID must be a string", mutation_ids:) unless body["requestID"].is_a?(String)
    end
    private_class_method :validate_body!

    def self.validate_query!(query, mutation_ids:)
      unless query.is_a?(Hash) && query["schema"].is_a?(String) && query["appID"].is_a?(String)
        raise ParseError.new(
          "Query parameters schema and appID are required",
          mutation_ids:,
          source: :query
        )
      end

      unless query["schema"].match?(/\A[a-z0-9_]+\z/)
        raise ParseError.new(
          "Query parameter schema is invalid",
          mutation_ids:,
          source: :query
        )
      end
    end
    private_class_method :validate_query!

    def self.extract_mutation_ids(body)
      return [] unless body.is_a?(Hash) && body["mutations"].is_a?(Array)

      body["mutations"].filter_map do |mutation|
        next unless mutation.is_a?(Hash)
        next unless mutation["clientID"].is_a?(String) && mutation["id"].is_a?(Numeric)

        {"clientID" => mutation["clientID"], "id" => mutation["id"]}
      end
    end
    private_class_method :extract_mutation_ids

    def initialize(**attributes)
      attributes.each { |name, value| instance_variable_set(:"@#{name}", value) }
    end

    def mutation_ids
      mutations.map(&:identifier)
    end
  end
end
