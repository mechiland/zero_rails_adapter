# Changelog

All notable changes to `zero-rails-adapter` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Because the project is still below 1.0, minor releases may contain breaking
changes; those changes are called out explicitly below.

## [Unreleased]

## [0.3.1] - 2026-07-29

### Security

- Changed request verification, authentication, and global mutation
  authorization defaults to fail closed. Applications must now configure every
  gate explicitly.
- Custom mutators without an `authorize_with` callback are rejected instead of
  executing implicitly. The mutator generator scaffolds an explicit
  deny-by-default callback.
- Generated initializers now require `ZERO_MUTATE_API_KEY` with `ENV.fetch`
  instead of silently disabling request verification when the variable is
  absent.
- Internal and database `PushFailed` responses no longer expose raw exception
  messages. Full errors remain available to the configured server logger.

### Fixed

- Persist only explicit application and validation failures before advancing
  LMID. Database failures and unexpected Ruby exceptions now roll back the
  mutation completely and return a retry-safe `PushFailed`, allowing the same
  mutation ID to succeed after the underlying problem is fixed.

### Changed

- Expanded the Zero 1.8 integration contract to use PostgreSQL UUID primary
  keys and foreign keys and to cover request verification, authentication,
  global and mutator authorization, sanitized internal failures, unchanged
  LMID state, and successful same-ID replay.
- Updated the contract's direct `ws` dependency from 8.18.3 to 8.21.1.

### Upgrade notes

Configure `request_verifier`, `authenticator`, and `authorizer` explicitly
before accepting mutation traffic. Add `authorize_with` to every custom
mutator, including mutators that intentionally rely only on the global
authorizer. Regenerate the initializer if the application still conditionally
configures `ZERO_MUTATE_API_KEY`.

## [0.3.0] - 2026-07-29

### Breaking changes

- Changed model and column exposure from permissive to fail-closed. The adapter
  no longer discovers and publishes every Active Record model by default.
  Applications must define `published_schema` with both the models and columns
  that Zero may replicate.
- Split the former `model_provider` responsibility into `published_schema` for
  replicated data and `crud_model_provider` for generic writes.
- Made generic CRUD fully opt-in. `crud_model_provider` now defaults to an empty
  list and `crud_authorizer` denies every operation by default. Publishing a
  model does not make it writable.
- Changed integer-backed Active Record enum generation from a string
  enumeration to `number()`. String-backed Active Record enums generate
  `string()`, while only PostgreSQL native enums generate Zero enumerations.

### Upgrade notes

Before upgrading an application from 0.2.0:

1. Replace `model_provider` with an explicit `published_schema` table-and-column
   allowlist.
2. If generic CRUD is required, configure both `crud_model_provider` and
   `crud_authorizer`. Keep them closed and use custom mutators for domain
   operations that enforce application invariants.
3. Regenerate `schema.ts` and `mutators.ts`.
4. Generate and review the column-limited PostgreSQL publication SQL, apply it
   through the application's normal database process, and point zero-cache at
   that publication.
5. Confirm that timestamp consumers treat Zero values as Unix epoch
   milliseconds and update any code that assumed string-valued Rails enums.

See the [README](README.md#explicit-publication-schema) for configuration
examples.

### Added

- Added a table-and-column publication schema with validation for primary keys,
  sensitive credentials, framework-internal tables, unknown columns, and
  unsupported PostgreSQL types.
- Added a generator for reviewable, column-limited PostgreSQL publication SQL.
- Added `zero_key` for stable synchronization identifiers that differ from the
  Active Record primary key, including composite keys. Separate keys must be
  published and backed by exact unique, non-null database indexes.
- Added explicit one-hop and two-hop relationship definitions for delegated,
  polymorphic, through, custom-key, and other associations Rails cannot safely
  infer.
- Added an exact Zero 1.8 integration contract using PostgreSQL logical
  replication, zero-cache, a Rails custom-mutator endpoint, and a real Zero
  client.
- Added coverage for replication queries, LMID advancement, duplicate
  mutations, failed-mutation skipping, and `_zero_cleanupResults`.

### Changed

- Generic update and destroy now locate records through the configured Zero
  key. Generic updates cannot change either the Zero key or the Active Record
  primary key.
- TypeScript generation now uses `published_schema` for tables and columns and
  generates CRUD mutators only for models returned by `crud_model_provider`.
- Timestamps are explicitly documented and generated as Unix epoch
  milliseconds on the Zero side.
- Manual relationships override inferred relationships with the same source
  and name.

### Security

- Added default rejection for known credential columns such as password hashes
  and token digests, authentication tables, Active Storage internals, and
  Action Mailbox internals.
- Publication validation rejects unsupported PostgreSQL types, including
  `citext`; applications must exclude those columns or publish a supported safe
  mirror column.
- Prevented schema generation and PostgreSQL publication generation from
  silently exposing newly discovered Active Record models or columns.

## [0.2.0] - 2026-07-28

### Added

- Initial public release.
- Added a mountable Rails Engine with Zero mutation endpoints.
- Added generic Active Record create, update, and destroy operations using
  validations, callbacks, associations, database constraints, and Rails
  transactions.
- Added explicit custom mutators through a Ruby DSL, base class, registry, and
  Rails generator.
- Added configurable request verification, authentication, authorization,
  model resolution, writable-attribute policies, and transaction storage.
- Added atomic Zero LMID tracking, mutation ordering, duplicate detection,
  structured application errors, failed-mutation skipping, and cleanup-result
  handling.
- Added TypeScript schema and mutator generation from Active Record models.
- Added Active Support mutation notifications and Rails/PostgreSQL test
  coverage.

[Unreleased]: https://github.com/mechiland/zero_rails_adapter/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/mechiland/zero_rails_adapter/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/mechiland/zero_rails_adapter/releases/tag/v0.3.0
[0.2.0]: https://rubygems.org/gems/zero-rails-adapter/versions/0.2.0
