# frozen_string_literal: true

require "minitest/autorun"
require "rubygems"

class GemspecTest < Minitest::Test
  REPOSITORY_URL = "https://github.com/mechiland/zero_rails_adapter"

  def setup
    @specification = Gem::Specification.load(
      File.expand_path("../zero-rails-adapter.gemspec", __dir__)
    )
  end

  def test_homepage_points_to_repository
    assert_equal REPOSITORY_URL, @specification.homepage
  end

  def test_metadata_points_to_project_resources
    expected_metadata = {
      "source_code_uri" => REPOSITORY_URL,
      "bug_tracker_uri" => "#{REPOSITORY_URL}/issues",
      "changelog_uri" => "#{REPOSITORY_URL}/blob/main/CHANGELOG.md",
      "documentation_uri" => "#{REPOSITORY_URL}#readme"
    }

    assert_equal expected_metadata, @specification.metadata.slice(*expected_metadata.keys)
  end
end
