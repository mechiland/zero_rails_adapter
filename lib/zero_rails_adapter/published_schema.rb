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

    def initialize(mapping, zero_key: ZeroRailsAdapter.configuration.zero_key)
      value = mapping.respond_to?(:call) ? mapping.call : mapping
      unless value.respond_to?(:to_h)
        raise UnsafePublicationError,
          "Published schema must be a model-to-columns mapping"
      end

      @zero_key = zero_key
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

    def zero_keys_for(model)
      keys = Array(@zero_key.call(model)).compact.map(&:to_s)
      return keys.freeze if keys.any?

      label = model.name.presence || model.table_name
      raise UnsafePublicationError, "#{label} must define at least one Zero key"
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

      validate_zero_key!(model, names, label)
      columns.freeze
    end

    def validate_zero_key!(model, published_names, label)
      keys = zero_keys_for(model)
      missing_keys = keys - published_names
      if missing_keys.any?
        key_label = missing_keys.one? ? "column" : "columns"
        raise UnsafePublicationError,
          "#{label} publication must include Zero key #{key_label} " \
          "#{missing_keys.join(', ')}"
      end

      active_record_keys = Array(model.primary_key).compact.map(&:to_s)
      return if keys == active_record_keys

      columns = keys.map { |key| model.columns_hash.fetch(key) }
      unique_index = model.connection.indexes(model.table_name).any? do |index|
        index.unique &&
          index.where.blank? &&
          Array(index.columns).map(&:to_s) == keys
      end
      return if columns.none?(&:null) && unique_index

      raise UnsafePublicationError,
        "#{label} Zero key #{keys.join(', ')} must be backed by a unique, non-null index"
    end
  end
end
