# frozen_string_literal: true

require_relative "lib/zero_rails_adapter/version"

Gem::Specification.new do |spec|
  spec.name = "zero-rails-adapter"
  spec.version = ZeroRailsAdapter::VERSION
  spec.authors = ["Zero Rails Adapter contributors"]
  spec.summary = "A Rails 8 Active Record adapter for Rocicorp Zero"
  spec.description = "Map Rocicorp Zero CRUD mutations to Active Record models, transactions, validations, and callbacks."
  spec.homepage = "https://github.com/mechiland/zero_rails_adapter"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  spec.files = Dir.chdir(__dir__) do
    Dir["{app,config,examples,lib}/**/*", "CHANGELOG.md", "LICENSE.txt", "README.md"]
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.0", "< 9.0"

  spec.metadata = {
    "rubygems_mfa_required" => "true",
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}#readme"
  }
end
