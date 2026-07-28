# frozen_string_literal: true

module ZeroRailsAdapter
  Identity = Data.define(:user_id, :current_user, :claims) do
    def initialize(user_id: nil, current_user: nil, claims: {})
      super(user_id: user_id&.to_s, current_user:, claims: claims || {})
    end
  end
end
