# frozen_string_literal: true

require "test_helper"

class RequestTest < ZeroTestCase
  def test_parses_a_valid_zero_push
    request = ZeroRailsAdapter::Request.parse(
      push_body(mutation(id: 1)),
      query: {"schema" => "zero_0", "appID" => "my-app"}
    )

    assert_equal "group-1", request.client_group_id
    assert_equal "zero_0", request.schema
    assert_equal "my-app", request.app_id
    assert_equal "books|create", request.mutations.first.name
  end

  def test_rejects_an_unsupported_push_version_with_protocol_error
    error = assert_raises(ZeroRailsAdapter::UnsupportedPushVersionError) do
      ZeroRailsAdapter::Request.parse(
        push_body(mutation(id: 1), pushVersion: 2),
        query: {"schema" => "zero_0", "appID" => "my-app"}
      )
    end

    assert_equal 2, error.version
  end

  def test_reports_all_known_mutation_ids_when_shape_is_invalid
    error = assert_raises(ZeroRailsAdapter::ParseError) do
      ZeroRailsAdapter::Request.parse(
        push_body(mutation(id: 1), mutation(id: 2).except("name")),
        query: {"schema" => "zero_0", "appID" => "my-app"}
      )
    end

    assert_equal(
      [{"clientID" => "client-1", "id" => 1}, {"clientID" => "client-1", "id" => 2}],
      error.mutation_ids
    )
  end

  def test_rejects_an_unsafe_upstream_schema_identifier
    error = assert_raises(ZeroRailsAdapter::ParseError) do
      ZeroRailsAdapter::Request.parse(
        push_body(mutation(id: 1)),
        query: {"schema" => 'zero_0"."clients', "appID" => "my-app"}
      )
    end

    assert_match "schema", error.message
    assert_equal [{"clientID" => "client-1", "id" => 1}], error.mutation_ids
  end
end
