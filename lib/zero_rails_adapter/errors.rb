# frozen_string_literal: true

module ZeroRailsAdapter
  class Error < StandardError; end

  class ApplicationError < Error
    attr_reader :details

    def initialize(message = nil, details: nil)
      @details = details
      super(message)
    end
  end

  class ValidationError < ApplicationError; end
  class ForbiddenError < ApplicationError; end
  class UnauthorizedError < Error; end
  class UnknownMutatorError < ApplicationError; end
  class UnsupportedColumnTypeError < Error; end
  class UnsafePublicationError < Error; end
  class InvalidRelationshipError < Error; end

  class ProtocolError < Error
    attr_reader :mutation_ids

    def initialize(message, mutation_ids: [])
      @mutation_ids = mutation_ids
      super(message)
    end
  end

  class ParseError < ProtocolError
    attr_reader :source

    def initialize(message, mutation_ids: [], source: :body)
      @source = source
      super(message, mutation_ids:)
    end
  end

  class UnsupportedPushVersionError < ProtocolError
    attr_reader :version

    def initialize(version, mutation_ids: [])
      @version = version
      super("Unsupported push version: #{version}", mutation_ids:)
    end
  end

  class OutOfOrderMutationError < ProtocolError; end
  class AlreadyProcessedError < Error; end
end
