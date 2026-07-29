# frozen_string_literal: true

require "active_record"
require "fileutils"
require "zero_rails_adapter"

database_url = ENV.fetch("DATABASE_URL")
generated_dir = ENV.fetch(
  "ZERO_CONTRACT_GENERATED_DIR",
  File.expand_path("generated", __dir__)
)

ActiveRecord::Base.establish_connection(database_url)
connection = ActiveRecord::Base.connection
connection.execute("DROP PUBLICATION IF EXISTS zero_contract_data")
connection.execute("DROP TABLE IF EXISTS contract_book_labels")
connection.execute("DROP TABLE IF EXISTS contract_labels")
connection.execute("DROP TABLE IF EXISTS contract_books")
connection.execute <<~SQL
  CREATE TABLE contract_books (
    id uuid PRIMARY KEY,
    sync_id text NOT NULL UNIQUE,
    title text NOT NULL,
    created_at timestamp NOT NULL,
    updated_at timestamp NOT NULL
  )
SQL
connection.execute <<~SQL
  CREATE TABLE contract_labels (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL
  )
SQL
connection.execute <<~SQL
  CREATE TABLE contract_book_labels (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    book_id uuid NOT NULL REFERENCES contract_books(id),
    label_id uuid NOT NULL REFERENCES contract_labels(id)
  )
SQL

class ContractBook < ActiveRecord::Base
end

class ContractLabel < ActiveRecord::Base
end

class ContractBookLabel < ActiveRecord::Base
end

published_schema = {
  ContractBook => %w[id sync_id title created_at updated_at],
  ContractBookLabel => %w[id book_id label_id],
  ContractLabel => %w[id name]
}
ZeroRailsAdapter.configuration.zero_key = lambda do |model|
  model == ContractBook ? "sync_id" : model.primary_key
end
publication = ZeroRailsAdapter::PostgreSQL::PublicationGenerator.new(
  name: "zero_contract_data",
  published_schema:
)
connection.execute(publication.sql)

generator = ZeroRailsAdapter::TypeScript::Generator.new(
  published_schema:,
  crud_models: [ContractBook],
  manual_relationships: [{
    source: ContractBook,
    name: :labels,
    kind: :many,
    through: [
      {
        source_fields: %w[id],
        destination: ContractBookLabel,
        destination_fields: %w[book_id]
      },
      {
        source_fields: %w[label_id],
        destination: ContractLabel,
        destination_fields: %w[id]
      }
    ]
  }]
)
FileUtils.mkdir_p(generated_dir)
File.write(File.join(generated_dir, "schema.ts"), generator.schema)
File.write(File.join(generated_dir, "mutators.ts"), generator.mutators)
