# frozen_string_literal: true

module ZeroRailsAdapter
  class Processor
    CLEANUP_MUTATION_NAME = "_zero_cleanupResults"

    attr_reader :request, :context, :storage

    def initialize(request:, context:)
      @request = request
      @context = context.with(request:)
      @storage = ZeroRailsAdapter.configuration.storage_provider.call(request)
    end

    def call
      responses = []
      processed_count = 0

      request.mutations.each do |mutation|
        if mutation.name == CLEANUP_MUTATION_NAME
          cleanup_results(mutation)
          processed_count += 1
          next
        end

        responses << ActiveSupport::Notifications.instrument(
          "mutation.zero_rails_adapter",
          name: mutation.name,
          client_id: mutation.client_id,
          mutation_id: mutation.id,
          client_group_id: request.client_group_id,
          app_id: request.app_id,
          schema: request.schema
        ) { process_mutation(mutation) }
        processed_count += 1
      end

      {
        "kind" => "MutateResponse",
        "mutations" => responses,
        "userID" => context.user_id
      }
    rescue OutOfOrderMutationError => error
      push_failed(
        reason: "oooMutation",
        message: error.message,
        mutation_ids: request.mutation_ids.drop(processed_count)
      )
    rescue ActiveRecord::ActiveRecordError => error
      push_failed(
        reason: "database",
        message: error.message,
        mutation_ids: request.mutation_ids.drop(processed_count)
      )
    rescue StandardError => error
      push_failed(
        reason: "internal",
        message: error.message,
        mutation_ids: request.mutation_ids.drop(processed_count)
      )
    end

    private

    def process_mutation(mutation)
      result = nil

      storage.transaction do
        expected = storage.increment_lmid!(mutation.client_id)
        check_order!(expected, mutation)
        authorized = ZeroRailsAdapter.configuration.authorizer.call(context, mutation)
        raise ForbiddenError, "Mutation is not authorized" unless authorized
        mutator = ZeroRailsAdapter.registry.find(mutation.name)
        result =
          if mutator
            mutator.call(mutation.argument, context:)
          else
            Crud::Dispatcher.new(context:).call(mutation)
          end
      end

      success_response(mutation, result)
    rescue AlreadyProcessedError => error
      already_processed_response(mutation, error)
    rescue OutOfOrderMutationError
      raise
    rescue StandardError => error
      application_error = normalize_application_error(error)
      begin
        persist_failure(mutation, application_error)
      rescue AlreadyProcessedError => concurrent_error
        return already_processed_response(mutation, concurrent_error)
      end
      mutation_response(mutation, application_result(application_error))
    end

    def persist_failure(mutation, error)
      storage.transaction do
        expected = storage.increment_lmid!(mutation.client_id)
        check_order!(expected, mutation)
        storage.write_result(
          client_id: mutation.client_id,
          mutation_id: mutation.id,
          result: application_result(error)
        )
      end
    end

    def check_order!(expected, mutation)
      if mutation.id < expected
        raise AlreadyProcessedError,
          "Ignoring mutation from #{mutation.client_id} with ID #{mutation.id} " \
          "as it was already processed. Expected: #{expected}"
      end
      return if mutation.id == expected

      raise OutOfOrderMutationError,
        "Client #{mutation.client_id} sent mutation ID #{mutation.id} but expected #{expected}"
    end

    def success_response(mutation, result)
      payload = {}
      payload["data"] = serializable(result) unless result.nil?
      mutation_response(mutation, payload)
    end

    def mutation_response(mutation, result)
      {"id" => mutation.identifier, "result" => result}
    end

    def already_processed_response(mutation, error)
      mutation_response(mutation, {
        "error" => "alreadyProcessed",
        "details" => error.message
      })
    end

    def normalize_application_error(error)
      return error if error.is_a?(ApplicationError)

      if error.respond_to?(:record) && error.record.respond_to?(:errors)
        return ApplicationError.new(error.message, details: error.record.errors.to_hash)
      end

      ApplicationError.new(error.message)
    end

    def application_result(error)
      result = {"error" => "app", "message" => error.message}
      result["details"] = serializable(error.details) unless error.details.nil?
      result
    end

    def serializable(value)
      value.as_json
    end

    def cleanup_results(mutation)
      args = mutation.argument
      return unless args.is_a?(Hash)
      storage.transaction { storage.cleanup(args) }
    rescue StandardError => error
      ZeroRailsAdapter.configuration.logger&.warn(
        "ZeroRailsAdapter cleanup failed: #{error.class}: #{error.message}"
      )
    end

    def push_failed(reason:, message:, mutation_ids:)
      {
        "kind" => "PushFailed",
        "origin" => "server",
        "reason" => reason,
        "message" => message,
        "mutationIDs" => mutation_ids
      }
    end
  end
end
