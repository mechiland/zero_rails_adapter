# frozen_string_literal: true

require "test_helper"

class MutatorTest < ZeroTestCase
  class CreateBook < ZeroRailsAdapter::Mutator
    mutation_name "mutator_test|create"

    attribute :title, :string
    validates :title, presence: true
    authorize_with { true }

    def perform
      Book.create!(title:, owner_id: context.current_user.id)
    end
  end

  User = Data.define(:id)

  def test_mutator_uses_active_model_attributes_and_validations
    identity = ZeroRailsAdapter::Identity.new(user_id: "7", current_user: User.new(7), claims: {})
    context = ZeroRailsAdapter::Context.new(identity:)

    error = assert_raises(ZeroRailsAdapter::ValidationError) do
      CreateBook.call({"title" => ""}, context:)
    end

    assert_equal({"title" => ["can't be blank"]}, error.details)
    assert_equal 0, Book.count
  end

  def test_mutator_exposes_context_and_returns_serializable_data
    identity = ZeroRailsAdapter::Identity.new(user_id: "7", current_user: User.new(7), claims: {})
    context = ZeroRailsAdapter::Context.new(identity:)

    result = CreateBook.call({"title" => "Dune"}, context:)

    assert_equal "Dune", Book.last.title
    assert_equal 7, Book.last.owner_id
    assert_equal Book.last, result
  end

  def test_inherited_mutator_is_registered_by_protocol_name
    assert_same CreateBook, ZeroRailsAdapter.registry.fetch("mutator_test|create")
    assert_same CreateBook, ZeroRailsAdapter.registry.fetch("mutator_test.create")
  end

  def test_mutator_can_handle_a_non_object_json_argument
    echo = Class.new(ZeroRailsAdapter::Mutator) do
      mutation_name "mutator_test|echo"
      authorize_with { true }

      define_method(:perform) { {"echo" => arguments} }
    end
    context = ZeroRailsAdapter::Context.new(identity: ZeroRailsAdapter::Identity.new)

    assert_equal({"echo" => "hello"}, echo.call("hello", context:))
  end

  def test_mutator_without_explicit_authorization_is_rejected
    mutator = Class.new(ZeroRailsAdapter::Mutator) do
      mutation_name "mutator_test|missing_authorization"
      define_method(:perform) { raise "must not run" }
    end
    context = ZeroRailsAdapter::Context.new(
      identity: ZeroRailsAdapter::Identity.new
    )

    error = assert_raises(ZeroRailsAdapter::ForbiddenError) do
      mutator.call({}, context:)
    end

    assert_equal "Mutator authorization is not configured", error.message
  end
end
