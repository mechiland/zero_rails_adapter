# frozen_string_literal: true

require "test_helper"

class PublicationGeneratorTest < ZeroTestCase
  def test_generates_a_column_limited_publication
    sql = ZeroRailsAdapter::PostgreSQL::PublicationGenerator.new(
      name: "zero_data",
      published_schema: {
        Article => %w[id title],
        ArticleEvent => %w[id article_id]
      }
    ).sql

    assert_equal <<~SQL, sql
      CREATE PUBLICATION "zero_data" FOR TABLE
        "articles" ("id", "title"),
        "article_events" ("id", "article_id");
    SQL
  end

  def test_rejects_a_column_that_does_not_exist
    error = assert_raises(ZeroRailsAdapter::UnsafePublicationError) do
      ZeroRailsAdapter::PostgreSQL::PublicationGenerator.new(
        published_schema: {Article => %w[id missing]}
      ).sql
    end

    assert_match "Article.missing does not exist", error.message
  end

  def test_rejects_a_publication_without_the_replica_identity
    error = assert_raises(ZeroRailsAdapter::UnsafePublicationError) do
      ZeroRailsAdapter::PostgreSQL::PublicationGenerator.new(
        published_schema: {Article => %w[title]}
      ).sql
    end

    assert_match "must include primary key column id", error.message
  end

  def test_rejects_known_sensitive_columns_even_when_allowlisted
    error = assert_raises(ZeroRailsAdapter::UnsafePublicationError) do
      ZeroRailsAdapter::PostgreSQL::PublicationGenerator.new(
        published_schema: {Article => %w[id password_hash]}
      ).sql
    end

    assert_match "Article.password_hash is forbidden", error.message
  end

  def test_rejects_a_known_authentication_table
    authentication_model = Class.new(ActiveRecord::Base) do
      self.table_name = "user_password_reset_keys"
    end

    error = assert_raises(ZeroRailsAdapter::UnsafePublicationError) do
      ZeroRailsAdapter::PostgreSQL::PublicationGenerator.new(
        published_schema: {authentication_model => %w[id]}
      ).sql
    end

    assert_match "user_password_reset_keys is an authentication table", error.message
  end
end
