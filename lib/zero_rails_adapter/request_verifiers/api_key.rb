# frozen_string_literal: true

require "active_support/security_utils"

module ZeroRailsAdapter
  module RequestVerifiers
    class ApiKey
      def initialize(key:, header: "X-Api-Key")
        @key = key.to_s
        @header = header
      end

      def call(request)
        candidate = request.headers[@header].to_s
        return false if @key.empty? || candidate.bytesize != @key.bytesize

        ActiveSupport::SecurityUtils.secure_compare(candidate, @key)
      end
    end
  end
end
