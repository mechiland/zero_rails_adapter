# frozen_string_literal: true

require "test_helper"

class TypeScriptGeneratorTest < ZeroTestCase
  def generator
    ZeroRailsAdapter::TypeScript::Generator.new(models: [Article, ArticleEvent])
  end

  def test_generates_zero_schema_from_active_record_columns_and_primary_keys
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

  def test_uses_the_configured_model_provider_when_models_are_not_passed
    ZeroRailsAdapter.configuration.model_provider = -> { [Article] }

    output = ZeroRailsAdapter::TypeScript::Generator.new.schema

    assert_includes output, "const articles = table('articles')"
    refute_includes output, "const articleEvents = table('article_events')"
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
