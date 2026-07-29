# frozen_string_literal: true

ZeroRailsAdapter.configure do |config|
  # zero-cache owns the schema.clients and schema.mutations tracking tables,
  # so this gem does not install a migration for them.

  # Verify that calls came from your zero-cache instance.
  # Configure zero-cache with ZERO_MUTATE_API_KEY using the same value.
  if ENV["ZERO_MUTATE_API_KEY"].present?
    config.request_verifier = ZeroRailsAdapter::RequestVerifiers::ApiKey.new(
      key: ENV.fetch("ZERO_MUTATE_API_KEY")
    )
  end

  # Return an Identity from any authentication system (Devise, JWT, cookies, etc.).
  # config.authenticator = lambda do |request|
  #   user = YourAuthentication.call(request)
  #   ZeroRailsAdapter::Identity.new(
  #     user_id: user&.id&.to_s,
  #     current_user: user,
  #     claims: {}
  #   )
  # end

  # This runs once per mutation, inside its database transaction.
  # Raise ZeroRailsAdapter::ForbiddenError to reject a mutation.
  # config.authorizer = ->(context, mutation) { YourPolicy.authorize!(context, mutation) }

  # Fail-closed table and column allowlist used by schema.ts and publication
  # SQL generation. No tables or columns are published by default.
  # config.published_schema = lambda do
  #   {
  #     Article => %w[id title body author_id created_at updated_at],
  #     Comment => %w[id article_id body author_id created_at updated_at]
  #   }
  # end

  # Generic CRUD is independently opt-in. Publishing a model does not make it
  # writable. The default crud_authorizer below also rejects every operation.
  # Keep this empty when writes require domain-specific mutators.
  # config.crud_model_provider = -> { [Article, Comment] }

  # Authorize generic CRUD independently of Devise/JWT/Pundit/etc. target is
  # the model class for create, and the loaded record for update/destroy.
  # config.crud_authorizer = lambda do |context, action, target, attributes|
  #   ApplicationPolicy.new(context.current_user, target).public_send("#{action}?")
  # end

  # Server-side mass-assignment policy. It is always enforced after auth.
  # config.writable_attributes = lambda do |model, action, context|
  #   ModelMutationPolicy.new(context.current_user, model, action).attributes
  # end

  # Static field allowlist used by the TypeScript generator. Keep
  # user-dependent decisions in writable_attributes/crud_authorizer.
  # config.generated_attributes = ->(model, action) { model.column_names - %w[admin] }

  # For Rails multi-database apps, use an abstract base class connected to the
  # same PostgreSQL database as zero-cache's upstream schema.
  # config.transaction_class = PrimaryApplicationRecord
end
