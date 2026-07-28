# frozen_string_literal: true

module ZeroRailsAdapter
  class Context
    attr_reader :identity, :request, :rack_request

    delegate :user_id, :current_user, :claims, to: :identity

    def initialize(identity:, request: nil, rack_request: nil)
      @identity = identity
      @request = request
      @rack_request = rack_request
    end

    def with(request: @request, rack_request: @rack_request)
      self.class.new(identity:, request:, rack_request:)
    end
  end
end
