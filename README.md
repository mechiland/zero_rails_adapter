# Zero Rails Adapter

`zero-rails-adapter` is a mountable Rails Engine that maps Rocicorp Zero custom
mutations directly to existing Active Record models.

The default CRUD path does not require a Ruby Mutator class for every model:

| Zero mutation | Rails call |
| --- | --- |
| `articles.create` / `articles.insert` | `Article.create!(attributes)` |
| `articles.update` | `Article.find(...).update!(attributes)` |
| `articles.destroy` / `articles.delete` | `Article.find(...).destroy!` |

Existing Active Record validations, callbacks, associations, `after_commit`
jobs, database constraints, and transaction behavior therefore work without
adapter-specific wrappers. Explicit Mutators are reserved for non-CRUD domain
commands, aggregate operations, and other custom behavior.

The gem does not depend on Devise, a JWT implementation, Pundit, or another
authorization framework. Authentication, authorization, model exposure, and
mass-assignment policies are all configurable callable interfaces.

## Requirements

- Ruby 4.0 or newer
- Rails 8.0 or newer
- PostgreSQL, the upstream database supported by Zero
- Current `@rocicorp/zero` and `zero-cache` releases

The Zero-managed `schema.clients` and `schema.mutations` tables and the
application tables must use the same database connection. In a Rails
multi-database application, configure `transaction_class` with the abstract
Active Record base class connected to that PostgreSQL database.

## Installation

Add the gem:

```ruby
# Gemfile
gem "zero-rails-adapter"
```

Install the bundle and initializer:

```sh
bundle install
bin/rails generate zero_rails_adapter:install
```

Mount the Engine:

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount ZeroRailsAdapter::Engine => "/zero"
end
```

Configure zero-cache:

```sh
ZERO_MUTATE_URL="https://api.example.com/zero/mutate"
ZERO_MUTATE_API_KEY="replace-with-a-long-random-secret"
```

The Engine accepts `POST /mutate`, `POST /push`, and `POST /` beneath its mount
point. `/mutate` is the recommended endpoint.

The gem intentionally installs no tracking-table migration. zero-cache creates
the `clients` and `mutations` tables in its shard schema, such as `zero_0`.
The adapter uses Zero's validated `schema` parameter to build schema-qualified
Active Record classes for those tables, then writes application data and the
LMID in the same transaction.

## Explicit Publication Schema

The adapter fails closed. No Active Record model or column is published, added
to generated TypeScript, or exposed to generic CRUD by default.

Declare both the tables and columns that may be replicated:

```ruby
ZeroRailsAdapter.configure do |config|
  config.published_schema = lambda do
    {
      Article => %w[id title body author_id created_at updated_at],
      Comment => %w[id article_id body author_id created_at updated_at]
    }
  end
end
```

The callable is evaluated when code is generated, so it remains safe across
Rails development reloads. Primary key columns must be present. Unknown
columns, known credential columns such as `password_hash` and `token_digest`,
Active Storage and Action Mailbox internal tables, and PostgreSQL types that
Zero cannot replicate are rejected.

Generate a reviewable, column-limited PostgreSQL publication:

```sh
bin/rails generate zero_rails_adapter:publication zero_data
```

This writes `db/zero_publication.sql`; it does not execute DDL automatically.
Apply the SQL through the application's normal migration or operations process,
then configure:

```sh
ZERO_APP_PUBLICATIONS=zero_data
```

## Generic Active Record CRUD

Generic CRUD is a separate, opt-in capability. Publishing a model never makes
it writable.

This client-side mutation:

```ts
await mutators.articles.create({
  id: crypto.randomUUID(),
  title: 'Rails and Zero',
})
```

reaches the Engine as `articles.create`. The adapter resolves `Article` from
the table name, applies the writable-attribute policy, and calls:

```ruby
Article.create!(id: "...", title: "Rails and Zero")
```

For `update` and `destroy`, the adapter first loads the record using the
model's primary key, including composite primary keys, and then calls
`update!` or `destroy!`. The bang methods are intentional: a validation,
callback, or database-constraint failure rolls back the complete business
transaction and produces a structured Zero application error.

Configure the models exposed to generic CRUD explicitly:

```ruby
ZeroRailsAdapter.configure do |config|
  config.crud_model_provider = -> { [Article, Comment] }
end
```

Models absent from `crud_model_provider` cannot be resolved by generic CRUD.
The default provider returns an empty list, and the default `crud_authorizer`
also rejects every operation. Applications must opt into both model resolution
and authorization. Applications with aggregate operations, tenant-scoped
commands, soft deletion, or other domain behavior should leave the provider
empty and use custom mutators.

If a table cannot be resolved through Rails naming conventions, replace the
resolver:

```ruby
config.model_resolver = ->(table_name) { LegacyModels.fetch(table_name) }
```

The resolver must return a non-abstract Active Record class.

## Generate Zero TypeScript from Rails Models

The frontend schema and generic CRUD mutators do not need to be maintained by
hand:

```sh
bin/rails generate zero_rails_adapter:typescript app/javascript/zero
```

The generator reflects on `published_schema` in the Rails runtime and writes:

- `schema.ts`, containing tables, columns, nullability, primary keys, and
  safely inferred `belongs_to`, `has_one`, and `has_many` relationships.
- `mutators.ts`, containing `create`, `update`, and `destroy` only for models
  returned by `crud_model_provider`, using Zero's current `defineMutator` /
  `defineMutators` API and Zod argument schemas.

Run the generator again after changing Rails migrations or model associations.
The output can live in Rails' JavaScript directory or be written directly into
an adjacent Next.js application:

```sh
bin/rails generate zero_rails_adapter:typescript ../web/src/zero
```

The default mappings follow Zero's PostgreSQL type conventions:

- string/text/uuid → `string()`
- integer/bigint/float/decimal → `number()`
- boolean → `boolean()`
- date/time/datetime/timestamp → `number()`
- json/jsonb → `json()`
- integer-backed Active Record enum → `number()`
- string-backed Active Record enum → `string()`
- PostgreSQL native enum → `enumeration<...>()`

Nullable columns use `.optional()`. Rails timestamps use `Date.now()` for the
optimistic client write and are Unix epoch milliseconds in Zero. They remain
managed normally by Rails on the server.
The generator raises a descriptive error for a column that cannot be mapped
reliably instead of emitting an incorrect type.

`generated_attributes` controls which fields appear in generated create and
update argument schemas:

```ruby
config.generated_attributes = lambda do |model, action|
  case model.name
  when "User" then %w[id name avatar_url]
  else model.column_names - %w[admin internal_state]
  end
end
```

This is a static code-generation policy and must not depend on the current
user. Runtime permissions must still be enforced through the authorization
and writable-attribute interfaces below.

## Authentication, Authorization, and Attribute Policies

The generated initializer supports `ZERO_MUTATE_API_KEY` and verifies
zero-cache's `X-Api-Key` header using a constant-time comparison.

The authentication interface receives the Rails request. It can integrate with
Devise/Warden, any JWT library, a session, or an application-specific
authentication system:

```ruby
ZeroRailsAdapter.configure do |config|
  config.authenticator = lambda do |request|
    user = request.env["warden"]&.user
    raise ZeroRailsAdapter::UnauthorizedError, "Sign in required" unless user

    ZeroRailsAdapter::Identity.new(
      user_id: user.id.to_s,
      current_user: user,
      claims: {"role" => user.role}
    )
  end
end
```

The global `authorizer` runs first inside every mutation transaction. The CRUD
authorizer then receives the model class as `target` for create, or the loaded
record for update and destroy:

```ruby
config.crud_authorizer = lambda do |context, action, target, attributes|
  MutationPolicy.new(
    context.current_user,
    action,
    target,
    attributes
  ).allowed?
end
```

The server-side mass-assignment allowlist can vary by model, action, and
authenticated identity:

```ruby
config.writable_attributes = lambda do |model, action, context|
  MutationPolicy.new(context.current_user, action, model).permitted_attributes
end
```

The default excludes readonly attributes, the STI inheritance column, and
Rails timestamps. Attributes outside the allowlist are not assigned. Client
mutation arguments must never be treated as identity or trusted authorization
data.

Return `false` or raise `ZeroRailsAdapter::ForbiddenError` to reject a
mutation. Raise `UnauthorizedError` for an authentication failure. A request
verifier that returns `false` also produces HTTP 401.

## Custom Domain Mutators

Use an explicit Mutator only when ordinary model CRUD cannot express the
operation, such as publishing an article with an audit event, issuing a command
across multiple aggregates, or invoking an external service:

```sh
bin/rails generate zero_rails_adapter:mutator articles.publish
```

```ruby
class Articles::PublishMutator < ZeroRailsAdapter::Mutator
  mutation_name "articles.publish"

  attribute :id, :string
  validates :id, presence: true

  authorize_with do |context|
    context.current_user.present?
  end

  def perform
    ArticlePublishing.call(Article.find(id), actor: context.current_user)
  end
end
```

An explicitly registered Mutator takes precedence over generic CRUD, so an
application may intentionally override `articles.create`. The Ruby DSL is also
available:

```ruby
ZeroRailsAdapter.define_mutator "projects.archive" do
  attribute :id, :string

  perform do
    Project.find(id).archive!(actor: context.current_user)
  end
end
```

Mutators use Active Model attributes and validations and share a transaction
with application writes and LMID tracking.

## Mutation Ordering and Transaction Semantics

For each `(schema, clientGroupID, clientID)`, the adapter:

1. Locks or creates the Zero client tracking row.
2. Rejects a mutation ID above the next expected ID.
3. Skips a mutation ID that has already been processed.
4. Executes the authorized Active Record operation inside a transaction.
5. Updates the LMID atomically.

When a business validation or callback fails, the first transaction rolls
back. A second transaction advances the LMID and stores a structured `app`
result so that a bad mutation is not retried forever and later mutations can
continue. If the second transaction also fails, the adapter returns a
retry-safe `PushFailed` response.

Each mutation owns an independent transaction. A later failure in the same
HTTP batch does not roll back earlier committed mutations.
`_zero_cleanupResults` removes acknowledged error results without advancing
the LMID.

## Observability

Every non-internal mutation emits an Active Support notification:

```ruby
ActiveSupport::Notifications.subscribe("mutation.zero_rails_adapter") do |event|
  Rails.logger.info(
    name: event.payload[:name],
    client_id: event.payload[:client_id],
    duration_ms: event.duration
  )
end
```

The payload also contains `mutation_id`, `client_group_id`, `app_id`, and
`schema`.

## Development and Testing

```sh
bundle install
bundle exec rake test
bundle exec gem build zero-rails-adapter.gemspec
```

The suite covers the mountable Engine endpoint, Zero protocol ordering and
error semantics, dynamic CRUD dispatch, Active Record validations, callbacks,
dependent destroy behavior, authorization hooks, TypeScript generation, and a
PostgreSQL contract test using Zero's exact tracking-table structure.

Run the complete contract suite against a dedicated PostgreSQL test database:

```sh
DATABASE_URL=postgres://localhost/zero_rails_adapter_test bundle exec rake test
```

See [`examples/nextjs`](examples/nextjs) for a Next.js integration fixture.

## References

- [Zero custom mutators](https://zero.rocicorp.dev/docs/mutators)
- [Zero schema](https://zero.rocicorp.dev/docs/schema)
- [Zero PostgreSQL support](https://zero.rocicorp.dev/docs/postgres-support)
- [Zero `process-mutations.ts`](https://github.com/rocicorp/mono/blob/main/packages/zero-server/src/process-mutations.ts)
- [Server implementation plan](https://jeremykreutzbender.com/blog/server-implementation-plan-rocicorp-zero-custom-mutators)
