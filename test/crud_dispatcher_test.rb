# frozen_string_literal: true

require "test_helper"

class CrudDispatcherTest < ZeroTestCase
  def setup
    super
    @identity = ZeroRailsAdapter::Identity.new(user_id: 7, claims: {"role" => "editor"})
    ZeroRailsAdapter.configuration.crud_model_provider = -> { [Article] }
    ZeroRailsAdapter.configuration.crud_authorizer =
      ->(_context, _action, _target, _attributes) { true }
  end

  def test_create_calls_active_record_and_its_callbacks
    response = process(
      mutation(
        id: 1,
        name: "articles.create",
        args: [{"id" => "article-1", "title" => "Rails"}]
      )
    )

    assert_equal({}, response.dig("mutations", 0, "result"))
    assert_equal "Rails", Article.find("article-1").title
    assert_equal ["created"], Article.find("article-1").article_events.pluck(:event)
  end

  def test_update_uses_active_record_validations_and_callbacks
    Article.create!(id: "article-1", title: "Before")

    response = process(
      mutation(
        id: 1,
        name: "articles.update",
        args: [{"id" => "article-1", "title" => "After"}]
      )
    )

    assert_equal({}, response.dig("mutations", 0, "result"))
    assert_equal "After", Article.find("article-1").title
    assert_equal %w[created updated], Article.find("article-1").article_events.pluck(:event)
  end

  def test_validation_failure_rolls_back_and_advances_lmid
    response = process(
      mutation(
        id: 1,
        name: "articles.create",
        args: [{"id" => "article-1", "title" => ""}]
      )
    )

    assert_equal 0, Article.count
    assert_equal 0, ArticleEvent.count
    assert_equal "app", response.dig("mutations", 0, "result", "error")
    assert_equal ["can't be blank"],
      response.dig("mutations", 0, "result", "details", "title")
    assert_equal 1, ZeroRailsAdapter::ClientMutation.last.last_mutation_id
  end

  def test_destroy_calls_destroy_and_dependent_callbacks
    article = Article.create!(id: "article-1", title: "Delete me")
    assert_equal 1, article.article_events.count

    process(
      mutation(
        id: 1,
        name: "articles.destroy",
        args: [{"id" => "article-1"}]
      )
    )

    refute Article.exists?("article-1")
    assert_equal 0, ArticleEvent.count
  end

  def test_crud_authorizer_receives_class_for_create_and_record_for_update
    targets = []
    ZeroRailsAdapter.configuration.crud_authorizer = lambda do |context, action, target, attributes|
      targets << [context.user_id, action, target, attributes]
      action == :create
    end

    create_response = process(
      mutation(
        id: 1,
        name: "articles.create",
        args: [{"id" => "article-1", "title" => "Allowed"}]
      )
    )
    update_response = process(
      mutation(
        id: 2,
        name: "articles.update",
        args: [{"id" => "article-1", "title" => "Denied"}]
      )
    )

    assert_equal({}, create_response.dig("mutations", 0, "result"))
    assert_equal "app", update_response.dig("mutations", 0, "result", "error")
    assert_same Article, targets.first[2]
    assert_instance_of Article, targets.last[2]
    assert_equal "Allowed", Article.find("article-1").title
  end

  def test_writable_attributes_policy_filters_mass_assignment
    ZeroRailsAdapter.configuration.writable_attributes = lambda do |model, action, context|
      assert_same Article, model
      assert_equal :create, action
      assert_equal "7", context.user_id
      %w[id title]
    end

    process(
      mutation(
        id: 1,
        name: "articles.create",
        args: [{
          "id" => "article-1",
          "title" => "Safe",
          "published" => true
        }]
      )
    )

    refute Article.find("article-1").published?
  end

  def test_update_finds_by_zero_key_without_allowing_primary_key_changes
    ZeroRailsAdapter.configuration.zero_key = lambda do |model|
      model == Article ? "sync_id" : model.primary_key
    end
    Article.create!(id: "article-1", sync_id: "sync-1", title: "Before")

    response = process(
      mutation(
        id: 1,
        name: "articles.update",
        args: [{
          "sync_id" => "sync-1",
          "id" => "replacement-id",
          "title" => "After"
        }]
      )
    )

    assert_equal({}, response.dig("mutations", 0, "result"))
    assert_equal "After", Article.find("article-1").title
    refute Article.exists?("replacement-id")
  end

  def test_destroy_finds_by_zero_key
    ZeroRailsAdapter.configuration.zero_key = lambda do |model|
      model == Article ? "sync_id" : model.primary_key
    end
    Article.create!(id: "article-1", sync_id: "sync-1", title: "Delete me")

    process(
      mutation(
        id: 1,
        name: "articles.destroy",
        args: [{"sync_id" => "sync-1"}]
      )
    )

    refute Article.exists?("article-1")
  end

  def test_explicit_custom_mutator_takes_precedence_over_crud_bridge
    custom = Class.new(ZeroRailsAdapter::Mutator) do
      mutation_name "articles.insert"
      attribute :id, :string

      define_method(:perform) { {"custom" => id} }
    end

    response = process(
      mutation(
        id: 1,
        name: "articles.insert",
        args: [{"id" => "custom-1"}]
      )
    )

    assert_same custom, ZeroRailsAdapter.registry.fetch("articles.insert")
    assert_equal({"custom" => "custom-1"},
      response.dig("mutations", 0, "result", "data"))
    assert_equal 0, Article.count
  end

  private

  def process(*mutations)
    request = ZeroRailsAdapter::Request.parse(
      push_body(*mutations),
      query: {"schema" => "zero_0", "appID" => "zero"}
    )
    context = ZeroRailsAdapter::Context.new(identity: @identity)
    ZeroRailsAdapter::Processor.new(request:, context:).call
  end
end
