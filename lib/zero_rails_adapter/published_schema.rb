# frozen_string_literal: true

module ZeroRailsAdapter
  class PublishedSchema
    SUPPORTED_COLUMN_TYPES = %i[
      bigint boolean date datetime decimal enum float integer json jsonb
      string text time timestamp uuid
    ].freeze
    FORBIDDEN_COLUMN_NAMES = %w[
      access_token api_key api_key_digest device_token key_digest
      password password_digest password_hash refresh_token secret secret_key
      token token_digest
    ].freeze
    FORBIDDEN_TABLE_PREFIXES = %w[
      action_mailbox_ active_storage_
    ].freeze
    FORBIDDEN_TABLE_NAMES = %w[
      user_login_change_keys user_lockouts user_password_reset_keys
      user_previous_password_hashes user_recovery_codes user_remember_keys
      user_verification_keys
    ].freeze

    attr_reader :models

    def initialize(mapping)
      value = mapping.respond_to?(:call) ? mapping.call : mapping
      unless value.respond_to?(:to_h)
        raise UnsafePublicationError,
          "Published schema must be a model-to-columns mapping"
      end

      @columns_by_model = value.to_h.each_with_object({}) do |(model, names), result|
        validate_model!(model)
        result[model] = validate_columns!(model, names)
      end
      @models = @columns_by_model.keys.freeze
    end

    def empty?
      models.empty?
    end

    def column_names_for(model)
      columns_for(model).map(&:name)
    end

    def columns_for(model)
      @columns_by_model.fetch(model)
    end

    private

    def validate_model!(model)
      unless model.is_a?(Class) &&
          model < ActiveRecord::Base &&
          !model.abstract_class?
        raise UnsafePublicationError,
          "#{model.inspect} is not an Active Record model"
      end

      if FORBIDDEN_TABLE_PREFIXES.any? { |prefix| model.table_name.start_with?(prefix) }
        raise UnsafePublicationError,
          "#{model.table_name} is an internal framework table"
      end

      if FORBIDDEN_TABLE_NAMES.include?(model.table_name)
        raise UnsafePublicationError,
          "#{model.table_name} is an authentication table"
      end
    end

    def validate_columns!(model, names)
      names = Array(names).map(&:to_s).uniq
      label = model.name.presence || model.table_name
      raise UnsafePublicationError, "#{label} must publish at least one column" if names.empty?

      unknown = names - model.column_names
      if unknown.any?
        raise UnsafePublicationError, "#{label}.#{unknown.first} does not exist"
      end

      forbidden = names.find { |name| FORBIDDEN_COLUMN_NAMES.include?(name) }
      if forbidden
        raise UnsafePublicationError, "#{label}.#{forbidden} is forbidden"
      end

      columns = names.map { |name| model.columns_hash.fetch(name) }
      unsupported = columns.find do |column|
        !SUPPORTED_COLUMN_TYPES.include?(column.type.to_sym)
      end
      if unsupported
        raise UnsafePublicationError,
          "#{label}.#{unsupported.name} uses unsupported PostgreSQL type " \
          "#{unsupported.sql_type}"
      end

      missing_keys = Array(model.primary_key).compact.map(&:to_s) - names
      if missing_keys.any?
        key_label = missing_keys.one? ? "column" : "columns"
        raise UnsafePublicationError,
          "#{label} publication must include primary key #{key_label} " \
          "#{missing_keys.join(', ')}"
      end

      columns.freeze
    end
  end
end
