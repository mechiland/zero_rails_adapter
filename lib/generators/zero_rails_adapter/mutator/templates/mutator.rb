# frozen_string_literal: true

class <%= class_name %> < ZeroRailsAdapter::Mutator
  mutation_name "<%= name %>"

  # Arguments are Active Model attributes and support normal Rails validations.
  # attribute :title, :string
  # validates :title, presence: true

  authorize_with do |_context|
    false
  end

  def perform
    raise NotImplementedError
  end
end
