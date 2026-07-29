# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

task default: :test

namespace :contract do
  desc "Install the exact Zero client and zero-cache contract dependencies"
  task :install do
    sh "npm ci --prefix test/contract"
  end

  desc "Run the Zero client, zero-cache, Rails, and PostgreSQL contract"
  task run: :install do
    ruby "test/contract/run.rb"
  end
end

desc "Run the complete Zero 1.8 integration contract"
task contract: "contract:run"
