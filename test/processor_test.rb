# frozen_string_literal: true

require "test_helper"
require "stringio"

class ProcessorTest < ZeroTestCase
  User = Data.define(:id)

  class CreateBook < ZeroRailsAdapter::Mutator
    mutation_name "books|create"
    attribute :title, :string
    validates :title, presence: true
    authorize_with { true }

    def perform
      Book.create!(title:, owner_id: context.current_user.id)
      {"bookID" => Book.last.id}
    end
  end

  def setup
    super
    ZeroRailsAdapter.configuration.authorizer =
      ->(_context, _mutation) { true }
    @log_output = StringIO.new
    ZeroRailsAdapter.configuration.logger = Logger.new(@log_output)
    ZeroRailsAdapter.registry.register(CreateBook)
    @identity = ZeroRailsAdapter::Identity.new(
      user_id: "42",
      current_user: User.new(42),
      claims: {"role" => "member"}
    )
  end

  def test_commits_business_data_and_lmid_in_one_transaction
    response = process(push_body(mutation(id: 1)))

    assert_equal "MutateResponse", response["kind"]
    assert_equal "42", response["userID"]
    assert_equal(
      [{"id" => {"clientID" => "client-1", "id" => 1}, "result" => {"data" => {"bookID" => Book.last.id}}}],
      response["mutations"]
    )
    assert_equal 1, Book.count
    assert_equal 1, ZeroRailsAdapter::ClientMutation.last.last_mutation_id
  end

  def test_validation_failure_rolls_back_data_advances_lmid_and_persists_result
    response = process(push_body(mutation(id: 1, args: [{"title" => ""}])))

    assert_equal 0, Book.count
    assert_equal 1, ZeroRailsAdapter::ClientMutation.last.last_mutation_id
    result = response.dig("mutations", 0, "result")
    assert_equal "app", result["error"]
    assert_equal({"title" => ["can't be blank"]}, result["details"])
    assert_equal result, ZeroRailsAdapter::MutationResult.last.result
  end

  def test_active_record_failure_rolls_back_partial_business_writes
    failing = Class.new(ZeroRailsAdapter::Mutator) do
      mutation_name "books|partial_failure"
      attribute :title, :string
      authorize_with { true }

      define_method(:perform) do
        Book.create!(title:, owner_id: 42)
        Book.create!(title: nil, owner_id: 42)
      end
    end
    ZeroRailsAdapter.registry.register(failing)

    response = process(push_body(mutation(id: 1, name: "books|partial_failure")))

    assert_equal 0, Book.count
    assert_equal "app", response.dig("mutations", 0, "result", "error")
    assert_equal ["can't be blank"],
      response.dig("mutations", 0, "result", "details", "title")
    assert_equal 1, ZeroRailsAdapter::ClientMutation.last.last_mutation_id
  end

  def test_programming_error_is_retry_safe_and_same_mutation_can_be_replayed
    failing = Class.new(ZeroRailsAdapter::Mutator) do
      mutation_name "books|programming_error"
      authorize_with { true }

      define_method(:perform) do
        raise NoMethodError, "private implementation detail"
      end
    end
    ZeroRailsAdapter.registry.register(failing)
    body = push_body(
      mutation(id: 1, name: "books|programming_error", args: [{}])
    )

    response = process(body)

    assert_equal "PushFailed", response["kind"]
    assert_equal "internal", response["reason"]
    assert_equal "Internal server error", response["message"]
    assert_equal(
      [{"clientID" => "client-1", "id" => 1}],
      response["mutationIDs"]
    )
    refute_includes response.to_json, "private implementation detail"
    assert_equal 0, ZeroRailsAdapter::ClientMutation.count
    assert_equal 0, ZeroRailsAdapter::MutationResult.count
    assert_includes @log_output.string, "private implementation detail"

    repaired = Class.new(ZeroRailsAdapter::Mutator) do
      mutation_name "books|programming_error"
      authorize_with { true }

      define_method(:perform) do
        Book.create!(title: "Recovered", owner_id: 42)
      end
    end
    ZeroRailsAdapter.registry.register(repaired)

    replay = process(body)

    assert_equal "MutateResponse", replay["kind"]
    assert_equal 1, ZeroRailsAdapter::ClientMutation.last.last_mutation_id
    assert_equal "Recovered", Book.last.title
  end

  def test_database_error_is_retry_safe_and_does_not_expose_details
    failing = Class.new(ZeroRailsAdapter::Mutator) do
      mutation_name "books|database_error"
      authorize_with { true }

      define_method(:perform) do
        raise ActiveRecord::ConnectionNotEstablished,
          "postgresql://user:secret@example.test/database"
      end
    end
    ZeroRailsAdapter.registry.register(failing)

    response = process(
      push_body(
        mutation(id: 1, name: "books|database_error", args: [{}])
      )
    )

    assert_equal "PushFailed", response["kind"]
    assert_equal "database", response["reason"]
    assert_equal "Database error", response["message"]
    refute_includes response.to_json, "secret"
    assert_equal 0, ZeroRailsAdapter::ClientMutation.count
    assert_equal 0, ZeroRailsAdapter::MutationResult.count
    assert_includes @log_output.string, "postgresql://user:secret@example.test/database"
  end

  def test_unknown_argument_is_persisted_as_an_application_failure
    mutator = Class.new(ZeroRailsAdapter::Mutator) do
      mutation_name "books|unknown_argument"
      attribute :title, :string
      authorize_with { true }

      define_method(:perform) { raise "must not run" }
    end
    ZeroRailsAdapter.registry.register(mutator)

    response = process(
      push_body(
        mutation(
          id: 1,
          name: "books|unknown_argument",
          args: [{"unexpected" => true}]
        )
      )
    )

    assert_equal "MutateResponse", response["kind"]
    assert_equal "app", response.dig("mutations", 0, "result", "error")
    assert_match(
      "unknown attribute 'unexpected'",
      response.dig("mutations", 0, "result", "message")
    )
    assert_equal 1, ZeroRailsAdapter::ClientMutation.last.last_mutation_id
    assert_equal 1, ZeroRailsAdapter::MutationResult.count
  end

  def test_duplicate_is_not_replayed
    process(push_body(mutation(id: 1)))

    duplicate = process(push_body(mutation(id: 1)))

    assert_equal 1, Book.count
    assert_equal "alreadyProcessed", duplicate.dig("mutations", 0, "result", "error")
  end

  def test_concurrent_commit_while_recording_a_failure_becomes_already_processed
    base_storage = ZeroRailsAdapter::Storage::RailsTables
    racing_storage = Class.new(base_storage) do
      def increment_lmid!(client_id)
        @lock_count = @lock_count.to_i + 1
        if @lock_count == 2
          raise ZeroRailsAdapter::AlreadyProcessedError,
            "mutation was committed by another request"
        end

        super
      end
    end
    ZeroRailsAdapter.configuration.storage_provider = lambda do |request|
      racing_storage.new(request:, transaction_class: ActiveRecord::Base)
    end

    response = process(push_body(mutation(id: 1, args: [{"title" => ""}])))

    assert_equal "alreadyProcessed", response.dig("mutations", 0, "result", "error")
    assert_equal "mutation was committed by another request",
      response.dig("mutations", 0, "result", "details")
  end

  def test_out_of_order_stops_the_batch_and_returns_unprocessed_ids
    response = process(push_body(mutation(id: 2), mutation(id: 3)))

    assert_equal "PushFailed", response["kind"]
    assert_equal "server", response["origin"]
    assert_equal "oooMutation", response["reason"]
    assert_equal(
      [
        {"clientID" => "client-1", "id" => 2},
        {"clientID" => "client-1", "id" => 3}
      ],
      response["mutationIDs"]
    )
    assert_equal 0, Book.count
  end

  def test_completed_mutations_remain_committed_when_a_later_one_is_out_of_order
    response = process(push_body(mutation(id: 1), mutation(id: 3)))

    assert_equal "PushFailed", response["kind"]
    assert_equal [{"clientID" => "client-1", "id" => 3}], response["mutationIDs"]
    assert_equal 1, Book.count
    assert_equal 1, ZeroRailsAdapter::ClientMutation.last.last_mutation_id
  end

  def test_global_authorizer_can_reject_without_coupling_to_an_auth_library
    ZeroRailsAdapter.configuration.authorizer = lambda do |context, _mutation|
      raise ZeroRailsAdapter::ForbiddenError, "members cannot write" unless context.claims["role"] == "admin"
    end

    response = process(push_body(mutation(id: 1)))

    assert_equal "app", response.dig("mutations", 0, "result", "error")
    assert_equal "members cannot write", response.dig("mutations", 0, "result", "message")
    assert_equal 0, Book.count
    assert_equal 1, ZeroRailsAdapter::ClientMutation.last.last_mutation_id
  end

  def test_global_authorizer_can_reject_by_returning_false
    ZeroRailsAdapter.configuration.authorizer = ->(_context, _mutation) { false }

    response = process(push_body(mutation(id: 1)))

    assert_equal "app", response.dig("mutations", 0, "result", "error")
    assert_equal "Mutation is not authorized", response.dig("mutations", 0, "result", "message")
    assert_equal 0, Book.count
  end

  def test_unknown_mutator_is_recorded_as_an_application_failure
    response = process(push_body(mutation(id: 1, name: "missing.mutator")))

    assert_equal "app", response.dig("mutations", 0, "result", "error")
    assert_match "Could not find mutator missing.mutator",
      response.dig("mutations", 0, "result", "message")
    assert_equal 1, ZeroRailsAdapter::ClientMutation.last.last_mutation_id
  end

  def test_lmid_is_scoped_by_app_schema_group_and_client
    first = ZeroRailsAdapter::Request.parse(
      push_body(mutation(id: 1)),
      query: {"schema" => "zero_0", "appID" => "first-app"}
    )
    second = ZeroRailsAdapter::Request.parse(
      push_body(mutation(id: 1)),
      query: {"schema" => "zero_0", "appID" => "second-app"}
    )
    context = ZeroRailsAdapter::Context.new(identity: @identity)

    ZeroRailsAdapter::Processor.new(request: first, context:).call
    ZeroRailsAdapter::Processor.new(request: second, context:).call

    assert_equal 2, Book.count
    assert_equal [1, 1], ZeroRailsAdapter::ClientMutation.order(:app_id).pluck(:last_mutation_id)
  end

  def test_cleanup_deletes_acknowledged_results_without_advancing_lmid_or_responding
    process(push_body(mutation(id: 1, args: [{"title" => ""}])))
    cleanup = mutation(
      id: 2,
      name: "_zero_cleanupResults",
      args: [{
        "type" => "single",
        "clientGroupID" => "group-1",
        "clientID" => "client-1",
        "upToMutationID" => 1
      }]
    )

    response = process(push_body(cleanup))

    assert_equal [], response["mutations"]
    assert_equal 0, ZeroRailsAdapter::MutationResult.count
    assert_equal 1, ZeroRailsAdapter::ClientMutation.last.last_mutation_id
  end

  def test_emits_active_support_instrumentation_for_each_business_mutation
    events = []
    subscriber = ->(event) { events << event }

    ActiveSupport::Notifications.subscribed(subscriber, "mutation.zero_rails_adapter") do
      process(push_body(mutation(id: 1)))
    end

    assert_equal 1, events.length
    assert_equal "books|create", events.first.payload[:name]
    assert_equal "client-1", events.first.payload[:client_id]
    assert_equal 1, events.first.payload[:mutation_id]
  end

  private

  def process(body)
    request = ZeroRailsAdapter::Request.parse(
      body,
      query: {"schema" => "zero_0", "appID" => "my-app"}
    )
    context = ZeroRailsAdapter::Context.new(identity: @identity)
    ZeroRailsAdapter::Processor.new(request:, context:).call
  end
end
