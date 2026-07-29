# frozen_string_literal: true

require "test_helper"
require "rails/generators"
require "rails/generators/test_case"
require "generators/zero_rails_adapter/install/install_generator"
require "generators/zero_rails_adapter/mutator/mutator_generator"
require "generators/zero_rails_adapter/publication/publication_generator"
require "generators/zero_rails_adapter/typescript/typescript_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests ZeroRailsAdapter::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  def test_generates_initializer_without_parallel_tracking_tables
    run_generator

    assert_file "config/initializers/zero_rails_adapter.rb" do |contents|
      assert_match "ZeroRailsAdapter.configure", contents
      assert_match(
        'key: ENV.fetch("ZERO_MUTATE_API_KEY")',
        contents
      )
      refute_match 'if ENV["ZERO_MUTATE_API_KEY"].present?', contents
    end
    assert_no_migration "db/migrate/create_zero_rails_adapter_tables.rb"
  end
end

class TypeScriptRailsGeneratorTest < Rails::Generators::TestCase
  tests ZeroRailsAdapter::Generators::TypeScriptGenerator
  destination File.expand_path("../../tmp/typescript_generator", __dir__)
  setup :prepare_destination
  setup { ZeroRailsAdapter.reset_configuration! }

  def test_generates_schema_and_generic_crud_mutators
    ZeroRailsAdapter.configuration.published_schema = lambda do
      {
        Article => Article.column_names - %w[password_hash internal_notes],
        ArticleEvent => ArticleEvent.column_names
      }
    end
    ZeroRailsAdapter.configuration.crud_model_provider =
      -> { [Article, ArticleEvent] }

    run_generator ["app/javascript/zero"]

    assert_file "app/javascript/zero/schema.ts" do |contents|
      assert_includes contents, "const articles = table('articles')"
    end
    assert_file "app/javascript/zero/mutators.ts" do |contents|
      assert_includes contents, "await tx.mutate.articles.insert"
    end
  ensure
    ZeroRailsAdapter.reset_configuration!
  end
end

class PublicationRailsGeneratorTest < Rails::Generators::TestCase
  tests ZeroRailsAdapter::Generators::PublicationGenerator
  destination File.expand_path("../../tmp/publication_generator", __dir__)
  setup :prepare_destination
  setup { ZeroRailsAdapter.reset_configuration! }

  def test_generates_a_reviewable_publication_sql_file
    ZeroRailsAdapter.configuration.published_schema =
      -> { {Article => %w[id title]} }

    run_generator ["zero_app"]

    assert_file "db/zero_publication.sql" do |contents|
      assert_includes contents, 'CREATE PUBLICATION "zero_app" FOR TABLE'
      assert_includes contents, '"articles" ("id", "title")'
    end
  ensure
    ZeroRailsAdapter.reset_configuration!
  end
end

class MutatorGeneratorTest < Rails::Generators::TestCase
  tests ZeroRailsAdapter::Generators::MutatorGenerator
  destination File.expand_path("../../tmp/mutator_generator", __dir__)
  setup :prepare_destination

  def test_generates_a_conventional_active_model_mutator
    run_generator ["books.create"]

    assert_file "app/mutators/books/create_mutator.rb" do |contents|
      assert_match "class Books::CreateMutator < ZeroRailsAdapter::Mutator", contents
      assert_match 'mutation_name "books.create"', contents
      assert_match "authorize_with", contents
      assert_match "false", contents
      assert_match "def perform", contents
    end
  end
end
