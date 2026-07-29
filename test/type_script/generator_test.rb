# frozen_string_literal: true

require "test_helper"

class TypeScriptGeneratorTest < ZeroTestCase
  def published_schema
    {
      Article => %w[
        id title published review_state visibility metadata created_at updated_at
      ],
      ArticleEvent => %w[id article_id event created_at updated_at]
    }
  end

  def generator
    ZeroRailsAdapter::TypeScript::Generator.new(
      published_schema:,
      crud_models: [Article, ArticleEvent]
    )
  end

  def test_generates_zero_schema_from_allowlisted_columns_and_primary_keys
    output = generator.schema

    assert_includes output, "import {boolean, createSchema, json, number, relationships, string, table}"
    assert_includes output, "const articles = table('articles')"
    assert_includes output, "id: string()"
    assert_includes output, "title: string()"
    assert_includes output, "published: boolean()"
    assert_includes output, "metadata: json().optional()"
    assert_includes output, "created_at: number()"
    assert_includes output, ".primaryKey('id')"
    assert_includes output, "export const schema = createSchema({"
    refute_includes output, "password_hash"
    refute_includes output, "internal_notes"
  end

  def test_maps_enums_from_the_database_storage_type
    output = generator.schema

    assert_includes output, "review_state: number()"
    assert_includes output, "visibility: string()"
    refute_includes output, "enumeration<"

    mutators = generator.mutators
    assert_includes mutators, "review_state: z.number()"
    assert_includes mutators, "visibility: z.string()"
    refute_includes mutators, "z.enum("
  end

  def test_rejects_a_sensitive_column_in_the_published_schema
    error = assert_raises(ZeroRailsAdapter::UnsafePublicationError) do
      ZeroRailsAdapter::TypeScript::Generator.new(
        published_schema: {Article => %w[id password_hash]}
      ).schema
    end

    assert_match "Article.password_hash is forbidden", error.message
  end

  def test_rejects_a_published_schema_without_the_primary_key
    error = assert_raises(ZeroRailsAdapter::UnsafePublicationError) do
      ZeroRailsAdapter::TypeScript::Generator.new(
        published_schema: {Article => %w[title]}
      ).schema
    end

    assert_match "must include primary key column id", error.message
  end

  def test_generates_zero_relationships_from_active_record_associations
    output = generator.schema

    assert_equal 1, output.scan("const articlesRelationships =").length
    assert_includes output, "article_events: many({"
    assert_includes output, "latest_event: one({"
    assert_includes output, "sourceField: ['id']"
    assert_includes output, "destSchema: articleEvents"
    assert_includes output, "destField: ['article_id']"
    assert_includes output, "article: one({"
    assert_includes output, "sourceField: ['article_id']"
    assert_includes output, "destSchema: articles"
    assert_includes output, "destField: ['id']"
  end

  def test_generates_generic_crud_mutators_using_current_zero_api
    output = generator.mutators

    assert_includes output, "defineMutators({"
    assert_includes output, "articles: {"
    assert_includes output, "create: defineMutator("
    assert_includes output, "update: defineMutator("
    assert_includes output, "destroy: defineMutator("
    assert_includes output, "await tx.mutate.articles.insert"
    assert_includes output, "await tx.mutate.articles.update"
    assert_includes output, "await tx.mutate.articles.delete(args)"
  end

  def test_generated_crud_arguments_follow_database_nullability_and_timestamps
    output = generator.mutators

    assert_includes output, "metadata: z.json().nullish()"
    assert_includes output, "published: z.boolean().optional()"
    assert_includes output, "created_at: now"
    assert_includes output, "updated_at: now"
    refute_match(/const articlesCreateArgs[\s\S]*?created_at: z\./, output)
    assert_includes output, "title: z.string().optional()"
  end

  def test_uses_the_configured_published_schema_when_schema_is_not_passed
    ZeroRailsAdapter.configuration.published_schema =
      -> { {Article => %w[id title]} }

    output = ZeroRailsAdapter::TypeScript::Generator.new.schema

    assert_includes output, "const articles = table('articles')"
    refute_includes output, "const articleEvents = table('article_events')"
  end

  def test_generates_crud_only_for_explicitly_enabled_models
    output = ZeroRailsAdapter::TypeScript::Generator.new(
      published_schema:,
      crud_models: [Article]
    ).mutators

    assert_includes output, "articles: {"
    refute_includes output, "article_events: {"
  end

  def test_rejects_crud_generation_for_an_unpublished_model
    error = assert_raises(ZeroRailsAdapter::UnsafePublicationError) do
      ZeroRailsAdapter::TypeScript::Generator.new(
        published_schema: {Article => %w[id title]},
        crud_models: [ArticleEvent]
      )
    end

    assert_match "CRUD models must also be published: ArticleEvent", error.message
  end

  def test_uses_the_configured_zero_key_for_schema_and_crud_arguments
    ZeroRailsAdapter.configuration.zero_key = lambda do |model|
      model == Article ? "sync_id" : model.primary_key
    end
    generator = ZeroRailsAdapter::TypeScript::Generator.new(
      published_schema: {
        Article => %w[id sync_id title created_at updated_at]
      },
      crud_models: [Article]
    )

    assert_includes generator.schema, ".primaryKey('sync_id')"
    assert_includes generator.mutators, "sync_id: z.string()"
    destroy_args = generator.mutators[/const articlesDestroyArgs.*?\n\}/m]
    assert_includes destroy_args, "sync_id: z.string()"
    refute_match(/^\s+id:/, destroy_args)
    update_args = generator.mutators[/const articlesUpdateArgs.*?\n\}/m]
    refute_match(/^\s+id:/, update_args)
  end

  def test_rejects_a_zero_key_without_a_unique_non_null_index
    ZeroRailsAdapter.configuration.zero_key = ->(_model) { "internal_notes" }

    error = assert_raises(ZeroRailsAdapter::UnsafePublicationError) do
      ZeroRailsAdapter::TypeScript::Generator.new(
        published_schema: {Article => %w[id internal_notes]}
      )
    end

    assert_match "Zero key internal_notes must be backed by a unique, non-null index",
      error.message
  end

  def test_adds_a_manual_direct_relationship
    output = ZeroRailsAdapter::TypeScript::Generator.new(
      published_schema: {
        Article => %w[id title],
        ArticleEvent => %w[id article_id event]
      },
      manual_relationships: [{
        source: Article,
        name: :audit_trail,
        kind: :many,
        source_fields: %w[id],
        destination: ArticleEvent,
        destination_fields: %w[article_id]
      }]
    ).schema

    assert_includes output, "audit_trail: many({"
    assert_includes output, "sourceField: ['id']"
    assert_includes output, "destSchema: articleEvents"
    assert_includes output, "destField: ['article_id']"
  end

  def test_reads_manual_relationships_from_the_configured_provider
    ZeroRailsAdapter.configuration.relationship_provider = -> do
      [{
        source: Article,
        name: :audit_trail,
        kind: :many,
        source_fields: %w[id],
        destination: ArticleEvent,
        destination_fields: %w[article_id]
      }]
    end

    output = ZeroRailsAdapter::TypeScript::Generator.new(
      published_schema: {
        Article => %w[id title],
        ArticleEvent => %w[id article_id event]
      }
    ).schema

    assert_includes output, "audit_trail: many({"
  end

  def test_adds_a_two_hop_manual_relationship
    output = ZeroRailsAdapter::TypeScript::Generator.new(
      published_schema: {
        Article => %w[id title],
        ArticleLabel => %w[id article_id label_id],
        Label => %w[id name]
      },
      manual_relationships: [{
        source: Article,
        name: :labels,
        kind: :many,
        through: [
          {
            source_fields: %w[id],
            destination: ArticleLabel,
            destination_fields: %w[article_id]
          },
          {
            source_fields: %w[label_id],
            destination: Label,
            destination_fields: %w[id]
          }
        ]
      }]
    ).schema

    assert_match(/labels: many\(\{.*destSchema: articleLabels.*\}, \{.*destSchema: labels/m,
      output)
  end

  def test_rejects_a_manual_relationship_with_more_than_two_hops
    error = assert_raises(ZeroRailsAdapter::InvalidRelationshipError) do
      ZeroRailsAdapter::TypeScript::Generator.new(
        published_schema: {
          Article => %w[id],
          ArticleLabel => %w[id article_id label_id],
          Label => %w[id]
        },
        manual_relationships: [{
          source: Article,
          name: :invalid,
          kind: :many,
          through: [
            {
              source_fields: %w[id],
              destination: ArticleLabel,
              destination_fields: %w[article_id]
            },
            {
              source_fields: %w[label_id],
              destination: Label,
              destination_fields: %w[id]
            },
            {
              source_fields: %w[id],
              destination: Article,
              destination_fields: %w[id]
            }
          ]
        }]
      )
    end

    assert_match "supports at most two hops", error.message
  end

  def test_rejects_a_manual_relationship_that_uses_an_unpublished_field
    error = assert_raises(ZeroRailsAdapter::InvalidRelationshipError) do
      ZeroRailsAdapter::TypeScript::Generator.new(
        published_schema: {
          Article => %w[id title],
          ArticleEvent => %w[id article_id]
        },
        manual_relationships: [{
          source: Article,
          name: :private_events,
          kind: :many,
          source_fields: %w[internal_notes],
          destination: ArticleEvent,
          destination_fields: %w[article_id]
        }]
      )
    end

    assert_match "source field internal_notes is not published", error.message
  end

  def test_generated_attributes_can_hide_client_writable_fields
    ZeroRailsAdapter.configuration.generated_attributes =
      ->(_model, _action) { %w[id title] }

    output = generator.mutators
    create_args = output[/const articlesCreateArgs.*?\n\}/m]
    insert = output[/await tx\.mutate\.articles\.insert\((.*?)\)/m, 1]

    refute_includes create_args, "published:"
    assert_includes insert, "published: false"
  end
end
