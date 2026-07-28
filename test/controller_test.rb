# frozen_string_literal: true

require "test_helper"
require_relative "dummy/config/application"

Dummy::Application.initialize! unless Dummy::Application.initialized?

class ControllerTest < ActionDispatch::IntegrationTest
  User = Data.define(:id)

  class CreateBook < ZeroRailsAdapter::Mutator
    mutation_name "controller_books|create"
    attribute :title, :string

    def perform
      Book.create!(title:, owner_id: context.current_user.id)
      {"id" => Book.last.id}
    end
  end

  def setup
    ZeroRailsAdapter.reset_configuration!
    ZeroRailsAdapter.configuration.storage_provider = lambda do |request|
      ZeroRailsAdapter::Storage::RailsTables.new(
        request:,
        transaction_class: ZeroRailsAdapter.configuration.transaction_class
      )
    end
    ZeroRailsAdapter.registry.register(CreateBook)
    ZeroRailsAdapter::ClientMutation.delete_all
    ZeroRailsAdapter::MutationResult.delete_all
    Book.delete_all
  end

  def test_mounted_mutate_endpoint_authenticates_and_processes_json
    ZeroRailsAdapter.configuration.authenticator = lambda do |request|
      assert_equal "Bearer good-token", request.authorization
      ZeroRailsAdapter::Identity.new(
        user_id: "9",
        current_user: User.new(9),
        claims: {"scope" => "write"}
      )
    end

    post "/zero/mutate?schema=zero_0&appID=my-app",
      params: JSON.generate(push_body(mutation(id: 1))),
      headers: {
        "CONTENT_TYPE" => "application/json",
        "AUTHORIZATION" => "Bearer good-token"
      }

    assert_response :ok
    assert_equal "MutateResponse", response.parsed_body["kind"]
    assert_equal "9", response.parsed_body["userID"]
    assert_equal 1, Book.count
  end

  def test_push_alias_is_available_for_older_zero_configuration
    post "/zero/push?schema=zero_0&appID=my-app",
      params: JSON.generate(push_body(mutation(id: 1))),
      headers: {"CONTENT_TYPE" => "application/json"}

    assert_response :ok
    assert_equal "MutateResponse", response.parsed_body["kind"]
  end

  def test_request_verifier_can_reject_zero_cache_before_authentication
    authenticated = false
    ZeroRailsAdapter.configuration.request_verifier = ->(_request) { false }
    ZeroRailsAdapter.configuration.authenticator = lambda do |_request|
      authenticated = true
      ZeroRailsAdapter::Identity.new
    end

    post_mutate(push_body(mutation(id: 1)))

    assert_response :unauthorized
    assert_equal "Unauthorized", response.parsed_body["kind"]
    refute authenticated
    assert_equal 0, Book.count
  end

  def test_authenticator_can_return_a_plain_hash_for_devise_or_jwt_adapters
    ZeroRailsAdapter.configuration.authenticator = lambda do |_request|
      {user_id: "13", current_user: User.new(13), claims: {"provider" => "custom"}}
    end

    post_mutate(push_body(mutation(id: 1)))

    assert_response :ok
    assert_equal "13", response.parsed_body["userID"]
    assert_equal 13, Book.last.owner_id
  end

  def test_authentication_failure_uses_a_reauthentication_status
    ZeroRailsAdapter.configuration.authenticator = lambda do |_request|
      raise ZeroRailsAdapter::UnauthorizedError, "token expired"
    end

    post_mutate(push_body(mutation(id: 1)))

    assert_response :unauthorized
    assert_equal(
      {"kind" => "Unauthorized", "origin" => "server", "message" => "token expired"},
      response.parsed_body
    )
  end

  def test_malformed_json_returns_protocol_parse_error
    post "/zero/mutate?schema=zero_0&appID=my-app",
      params: "{bad json",
      headers: {"CONTENT_TYPE" => "application/json"}

    assert_response :ok
    assert_equal "PushFailed", response.parsed_body["kind"]
    assert_equal "parse", response.parsed_body["reason"]
    assert_equal [], response.parsed_body["mutationIDs"]
  end

  def test_unsupported_push_version_returns_protocol_error
    post_mutate(push_body(mutation(id: 1), pushVersion: 99))

    assert_response :ok
    assert_equal "unsupportedPushVersion", response.parsed_body["reason"]
    assert_equal [{"clientID" => "controller-client", "id" => 1}], response.parsed_body["mutationIDs"]
  end

  def test_missing_query_parameters_are_reported_separately_from_the_json_body
    post "/zero/mutate",
      params: JSON.generate(push_body(mutation(id: 1))),
      headers: {"CONTENT_TYPE" => "application/json"}

    assert_response :ok
    assert_equal "parse", response.parsed_body["reason"]
    assert_match "Failed to parse push query parameters", response.parsed_body["message"]
    assert_equal [{"clientID" => "controller-client", "id" => 1}],
      response.parsed_body["mutationIDs"]
  end

  private

  def post_mutate(body)
    post "/zero/mutate?schema=zero_0&appID=my-app",
      params: JSON.generate(body),
      headers: {"CONTENT_TYPE" => "application/json"}
  end

  def push_body(*mutations, **overrides)
    {
      "clientGroupID" => "group-1",
      "mutations" => mutations,
      "pushVersion" => 1,
      "timestamp" => 1_753_139_962_914,
      "requestID" => "request-1"
    }.merge(overrides.transform_keys(&:to_s))
  end

  def mutation(id:, name: "controller_books|create", args: [{"title" => "Dune"}])
    {
      "type" => "custom",
      "id" => id,
      "clientID" => "controller-client",
      "name" => name,
      "args" => args,
      "timestamp" => 1_753_139_962_891
    }
  end
end
