# frozen_string_literal: true

module ZeroRailsAdapter
  class Mutator
    include ActiveModel::Model
    include ActiveModel::Attributes

    class_attribute :configured_mutation_name, instance_writer: false
    class_attribute :authorization_callback, instance_writer: false

    attr_reader :arguments, :context

    class << self
      def mutation_name(name = nil)
        return configured_mutation_name if name.nil?

        self.configured_mutation_name = name.to_s
        ZeroRailsAdapter.registry.register(self)
      end

      def authorize_with(callable = nil, &block)
        self.authorization_callback = callable || block
      end

      def perform(&block)
        define_method(:perform, &block)
      end

      def call(arguments = {}, context:)
        new(arguments, context:).call
      end
    end

    def initialize(arguments = {}, context:)
      @arguments = arguments
      @context = context
      attributes = arguments.respond_to?(:to_h) ? arguments.to_h.symbolize_keys : {}
      super(attributes)
    end

    def call
      validate_arguments!
      authorize!
      perform
    end

    def perform
      raise NotImplementedError, "#{self.class.name} must implement #perform"
    end

    private

    def validate_arguments!
      return if valid?

      raise ValidationError.new(
        "Mutation arguments are invalid",
        details: errors.to_hash.stringify_keys
      )
    end

    def authorize!
      callback = self.class.authorization_callback
      unless callback
        raise ForbiddenError, "Mutator authorization is not configured"
      end
      return true if instance_exec(context, &callback)

      raise ForbiddenError, "Mutation is not authorized"
    end
  end
end
