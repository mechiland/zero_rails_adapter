# frozen_string_literal: true

module ZeroRailsAdapter
  class MutationsController < ActionController::API
    def create
      verify_request!
      identity = authenticate!
      zero_request = Request.parse(parsed_body, query: request.query_parameters)
      context = Context.new(identity:, request: zero_request, rack_request: request)

      render json: Processor.new(request: zero_request, context:).call, status: :ok
    rescue JSON::ParserError => error
      render json: push_failed("parse", "Failed to parse push body: #{error.message}", []),
        status: :ok
    rescue ParseError => error
      subject = error.source == :query ? "push query parameters" : "push body"
      render json: push_failed("parse", "Failed to parse #{subject}: #{error.message}", error.mutation_ids),
        status: :ok
    rescue UnsupportedPushVersionError => error
      render json: push_failed("unsupportedPushVersion", error.message, error.mutation_ids),
        status: :ok
    rescue UnauthorizedError => error
      render json: authentication_error(error), status: :unauthorized
    rescue ForbiddenError => error
      render json: authentication_error(error), status: :forbidden
    rescue StandardError => error
      ZeroRailsAdapter.configuration.logger&.error(
        "ZeroRailsAdapter request failed: #{error.class}: #{error.message}"
      )
      render json: push_failed(
        "internal",
        Processor::INTERNAL_ERROR_MESSAGE,
        []
      ), status: :internal_server_error
    end

    private

    def parsed_body
      JSON.parse(request.raw_post)
    end

    def verify_request!
      verified = ZeroRailsAdapter.configuration.request_verifier.call(request)
      raise UnauthorizedError, "Zero request verification failed" unless verified
    end

    def authenticate!
      value = ZeroRailsAdapter.configuration.authenticator.call(request)
      return value if value.is_a?(Identity)

      attributes = value.respond_to?(:to_h) ? value.to_h.symbolize_keys : {}
      Identity.new(
        user_id: attributes[:user_id],
        current_user: attributes[:current_user],
        claims: attributes[:claims] || {}
      )
    end

    def push_failed(reason, message, mutation_ids)
      {
        "kind" => "PushFailed",
        "origin" => "server",
        "reason" => reason,
        "message" => message,
        "mutationIDs" => mutation_ids
      }
    end

    def authentication_error(error)
      {
        "kind" => "Unauthorized",
        "origin" => "server",
        "message" => error.message
      }
    end
  end
end
