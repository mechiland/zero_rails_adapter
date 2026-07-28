# frozen_string_literal: true

module ZeroRailsAdapter
  module Crud
    class Dispatcher
      ACTIONS = {
        "create" => :create,
        "insert" => :create,
        "update" => :update,
        "destroy" => :destroy,
        "delete" => :destroy
      }.freeze

      attr_reader :context

      def initialize(context:)
        @context = context
      end

      def call(mutation)
        resource, action = parse_name(mutation.name)
        model = resolve_model(resource)
        attributes = normalize_arguments(mutation.argument)

        case action
        when :create
          create(model, attributes)
        when :update
          update(model, attributes)
        when :destroy
          destroy(model, attributes)
        end
      end

      private

      def parse_name(name)
        resource, action_name = name.to_s.split(".", 2)
        action = ACTIONS[action_name]
        unless resource&.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/) && action
          raise UnknownMutatorError, "Could not find mutator #{name}"
        end

        [resource, action]
      end

      def resolve_model(resource)
        model = ZeroRailsAdapter.configuration.model_resolver.call(resource)
        return model if model.is_a?(Class) && model < ActiveRecord::Base

        raise UnknownMutatorError, "Could not resolve Active Record model for #{resource}"
      end

      def normalize_arguments(arguments)
        unless arguments.respond_to?(:to_h)
          raise ValidationError, "CRUD mutation arguments must be an object"
        end

        arguments.to_h.stringify_keys
      end

      def create(model, attributes)
        authorize!(:create, model, attributes)
        model.create!(writable(model, :create, attributes))
        nil
      end

      def update(model, attributes)
        record = find_record!(model, attributes)
        authorize!(:update, record, attributes)
        changes = writable(model, :update, attributes).except(*primary_keys(model))
        record.update!(changes)
        nil
      end

      def destroy(model, attributes)
        record = find_record!(model, attributes)
        authorize!(:destroy, record, attributes)
        record.destroy!
        nil
      end

      def find_record!(model, attributes)
        keys = primary_keys(model)
        values = attributes.slice(*keys)
        missing = keys - values.keys
        if missing.any?
          raise ValidationError.new(
            "Missing primary key attributes: #{missing.join(', ')}",
            details: {"primaryKey" => missing}
          )
        end

        model.find_by!(values)
      end

      def primary_keys(model)
        Array(model.primary_key).map(&:to_s)
      end

      def authorize!(action, target, attributes)
        allowed = ZeroRailsAdapter.configuration.crud_authorizer.call(
          context,
          action,
          target,
          attributes
        )
        raise ForbiddenError, "Mutation is not authorized" unless allowed
      end

      def writable(model, action, attributes)
        allowed = ZeroRailsAdapter.configuration.writable_attributes.call(
          model,
          action,
          context
        )
        attributes.slice(*Array(allowed).map(&:to_s))
      end
    end
  end
end
