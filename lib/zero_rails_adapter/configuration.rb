# frozen_string_literal: true

module ZeroRailsAdapter
  class Configuration
    attr_accessor :authenticator, :request_verifier, :authorizer, :logger,
      :transaction_class, :storage_provider, :crud_authorizer,
      :writable_attributes, :generated_attributes, :model_resolver,
      :published_schema, :crud_model_provider

    def initialize
      @authenticator = ->(_request) { Identity.new }
      @request_verifier = ->(_request) { true }
      @authorizer = ->(_context, _mutation) { true }
      @crud_authorizer = ->(_context, _action, _target, _attributes) { false }
      @logger = defined?(Rails) ? Rails.logger : nil
      @transaction_class = ActiveRecord::Base
      @published_schema = -> { {} }
      @crud_model_provider = -> { [] }
      @model_resolver = lambda do |resource|
        allowed_models = Array(crud_model_provider.call).select do |model|
          active_record_model?(model)
        end
        candidate = resource.to_s.classify.safe_constantize
        candidate = nil unless allowed_models.include?(candidate)
        candidate ||= allowed_models.find { |model| model.table_name == resource.to_s }
      end
      @writable_attributes = ->(model, _action, _context) { default_writable_attributes(model) }
      @generated_attributes = ->(model, _action) { default_writable_attributes(model) }
      @storage_provider = lambda do |request|
        Storage::ZeroSchema.new(request:, transaction_class:)
      end
    end

    private

    def default_writable_attributes(model)
      model.column_names -
        model.readonly_attributes.to_a -
        [model.inheritance_column, "created_at", "updated_at"]
    end

    def active_record_model?(candidate)
      candidate.is_a?(Class) &&
        candidate < ActiveRecord::Base &&
        !candidate.abstract_class?
    end
  end
end
