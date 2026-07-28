# frozen_string_literal: true

class <%= class_name %> < ZeroRailsAdapter::Mutator
  mutation_name "<%= name %>"

  # Arguments are Active Model attributes and support normal Rails validations.
  # attribute :title, :string
  # validates :title, presence: true

  def perform
    # Use context.current_user, context.user_id, and context.claims for authorization.
    raise NotImplementedError
  end
end
