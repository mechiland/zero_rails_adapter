# frozen_string_literal: true

require "test_helper"

class ZeroSchemaStorageTest < ZeroTestCase
  def test_maps_tracking_to_the_tables_published_by_zero_cache
    request = ZeroRailsAdapter::Request.parse(
      push_body(mutation(id: 1)),
      query: {"schema" => "zero_0", "appID" => "zero"}
    )

    storage = ZeroRailsAdapter::Storage::ZeroSchema.new(
      request:,
      transaction_class: ActiveRecord::Base
    )

    assert_equal "zero_0.clients", storage.client_model.table_name
    assert_equal "zero_0.mutations", storage.mutation_result_model.table_name
    assert_equal %w[clientGroupID clientID], storage.client_model.primary_key
    assert_equal %w[clientGroupID clientID mutationID],
      storage.mutation_result_model.primary_key
  end
end
