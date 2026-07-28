# frozen_string_literal: true

require "test_helper"

class ZeroSchemaPostgresqlTest < ZeroTestCase
  class FailingBook < ZeroRailsAdapter::Mutator
    mutation_name "postgres_books.create"
    attribute :title, :string
    validates :title, presence: true

    def perform
      Book.create!(title:, owner_id: 1)
    end
  end

  def setup
    skip "PostgreSQL integration test" unless postgresql?
    super
    create_zero_schema
    ZeroRailsAdapter.reset_configuration!
    ZeroRailsAdapter.registry.register(FailingBook)
  end

  def teardown
    ActiveRecord::Base.connection.execute('DROP SCHEMA IF EXISTS "zero_0" CASCADE') if postgresql?
    super
  end

  def test_real_zero_schema_tracks_lmid_and_publishes_application_results
    context = ZeroRailsAdapter::Context.new(identity: ZeroRailsAdapter::Identity.new)
    request = ZeroRailsAdapter::Request.parse(
      push_body(
        mutation(id: 1, name: "postgres_books.create", args: [{"title" => ""}]),
        mutation(id: 2, name: "postgres_books.create", args: [{"title" => "Dune"}])
      ),
      query: {"schema" => "zero_0", "appID" => "zero"}
    )

    response = ZeroRailsAdapter::Processor.new(request:, context:).call

    assert_equal "MutateResponse", response["kind"]
    assert_equal "app", response.dig("mutations", 0, "result", "error")
    assert_equal 1, Book.count
    client = ActiveRecord::Base.connection.select_one(
      'SELECT * FROM "zero_0"."clients" WHERE "clientID" = \'client-1\''
    )
    assert_equal 2, client["lastMutationID"].to_i
    result = ActiveRecord::Base.connection.select_one(
      'SELECT * FROM "zero_0"."mutations" WHERE "mutationID" = 1'
    )
    assert_equal "app", JSON.parse(result["result"]).fetch("error")
  end

  private

  def postgresql?
    ActiveRecord::Base.connection.adapter_name == "PostgreSQL"
  end

  def create_zero_schema
    connection = ActiveRecord::Base.connection
    connection.execute('DROP SCHEMA IF EXISTS "zero_0" CASCADE')
    connection.execute('CREATE SCHEMA "zero_0"')
    connection.execute <<~SQL
      CREATE TABLE "zero_0"."clients" (
        "clientGroupID" TEXT NOT NULL,
        "clientID" TEXT NOT NULL,
        "lastMutationID" BIGINT NOT NULL,
        "userID" TEXT,
        PRIMARY KEY ("clientGroupID", "clientID")
      )
    SQL
    connection.execute <<~SQL
      CREATE TABLE "zero_0"."mutations" (
        "clientGroupID" TEXT NOT NULL,
        "clientID" TEXT NOT NULL,
        "mutationID" BIGINT NOT NULL,
        "result" JSON NOT NULL,
        PRIMARY KEY ("clientGroupID", "clientID", "mutationID")
      )
    SQL
  end
end
