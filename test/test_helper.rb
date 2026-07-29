# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "minitest/autorun"
require "minitest/pride"
require "active_record"
require "action_controller/railtie"
require "action_view/railtie"
require "rack/test"
require "zero_rails_adapter"
require_relative "support/rails_tables_storage"

ActiveRecord::Base.establish_connection(
  ENV["DATABASE_URL"] || {adapter: "sqlite3", database: ":memory:"}
)

ActiveRecord::Schema.define do
  create_table :zero_rails_adapter_client_mutations, force: true do |t|
    t.string :app_id, null: false
    t.string :schema_name, null: false
    t.string :client_group_id, null: false
    t.string :client_id, null: false
    t.bigint :last_mutation_id, null: false, default: 0
    t.timestamps
  end

  add_index :zero_rails_adapter_client_mutations,
    %i[app_id schema_name client_group_id client_id],
    unique: true,
    name: "idx_zero_client_mutations_identity"

  create_table :zero_rails_adapter_mutation_results, force: true do |t|
    t.string :app_id, null: false
    t.string :schema_name, null: false
    t.string :client_group_id, null: false
    t.string :client_id, null: false
    t.bigint :mutation_id, null: false
    t.json :result, null: false
    t.timestamps
  end

  add_index :zero_rails_adapter_mutation_results,
    %i[app_id schema_name client_group_id client_id mutation_id],
    unique: true,
    name: "idx_zero_mutation_results_identity"

  create_table :books, force: true do |t|
    t.string :title, null: false
    t.integer :owner_id, null: false
    t.timestamps
  end

  create_table :articles, id: false, force: true do |t|
    t.string :id, null: false, primary_key: true
    t.string :sync_id, null: false, default: "default-sync"
    t.string :title, null: false
    t.boolean :published, null: false, default: false
    t.integer :review_state, null: false, default: 0
    t.string :visibility, null: false, default: "public"
    t.string :password_hash
    t.string :internal_notes
    t.json :metadata
    t.timestamps null: false
  end
  add_index :articles, :sync_id, unique: true

  create_table :article_events, force: true do |t|
    t.string :article_id, null: false
    t.string :event, null: false
    t.timestamps
  end

  create_table :labels, id: false, force: true do |t|
    t.string :id, null: false, primary_key: true
    t.string :name, null: false
  end

  create_table :article_labels, force: true do |t|
    t.string :article_id, null: false
    t.string :label_id, null: false
  end
end

class Book < ActiveRecord::Base
  validates :title, presence: true
end

class Article < ActiveRecord::Base
  enum :review_state, {draft: 0, reviewed: 1}
  enum :visibility, {public: "public", private: "private"}, prefix: true

  has_many :article_events, dependent: :destroy
  has_one :latest_event, -> { order(id: :desc) }, class_name: "ArticleEvent"

  validates :title, presence: true

  after_create { article_events.create!(event: "created") }
  after_update { article_events.create!(event: "updated") }
end

class ArticleEvent < ActiveRecord::Base
  belongs_to :article
end

class Label < ActiveRecord::Base
end

class ArticleLabel < ActiveRecord::Base
end

class ZeroTestCase < Minitest::Test
  def setup
    ZeroRailsAdapter.reset_configuration!
    use_test_storage!
    ZeroRailsAdapter::ClientMutation.delete_all
    ZeroRailsAdapter::MutationResult.delete_all
    Book.delete_all
    ArticleEvent.delete_all
    ArticleLabel.delete_all
    Label.delete_all
    Article.delete_all
  end

  def push_body(*mutations, **overrides)
    {
      "clientGroupID" => "group-1",
      "mutations" => mutations,
      "pushVersion" => 1,
      "timestamp" => 1_753_139_962_914,
      "requestID" => "request-1"
    }.merge(overrides.transform_keys(&:to_s))
  end

  def mutation(id:, name: "books|create", args: [{"title" => "Dune"}], client_id: "client-1")
    {
      "type" => "custom",
      "id" => id,
      "clientID" => client_id,
      "name" => name,
      "args" => args,
      "timestamp" => 1_753_139_962_891
    }
  end

  def use_test_storage!
    ZeroRailsAdapter.configuration.storage_provider = lambda do |request|
      ZeroRailsAdapter::Storage::RailsTables.new(
        request:,
        transaction_class: ZeroRailsAdapter.configuration.transaction_class
      )
    end
  end
end
