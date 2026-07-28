# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < ZeroTestCase
  def test_configure_exposes_framework_agnostic_hooks
    authenticator = ->(request) { request }
    verifier = ->(request) { request }
    authorizer = ->(context, mutation) { [context, mutation] }
    crud_authorizer = ->(context, action, target, attributes) do
      [context, action, target, attributes]
    end
    generated_attributes = ->(model, action) { [model, action] }

    ZeroRailsAdapter.configure do |config|
      config.authenticator = authenticator
      config.request_verifier = verifier
      config.authorizer = authorizer
      config.crud_authorizer = crud_authorizer
      config.generated_attributes = generated_attributes
      config.transaction_class = Book
    end

    assert_same authenticator, ZeroRailsAdapter.configuration.authenticator
    assert_same verifier, ZeroRailsAdapter.configuration.request_verifier
    assert_same authorizer, ZeroRailsAdapter.configuration.authorizer
    assert_same crud_authorizer, ZeroRailsAdapter.configuration.crud_authorizer
    assert_same generated_attributes,
      ZeroRailsAdapter.configuration.generated_attributes
    assert_same Book, ZeroRailsAdapter.configuration.transaction_class
  end

  def test_reset_configuration_restores_safe_defaults
    ZeroRailsAdapter.configuration.authenticator = ->(_request) { raise "called" }

    ZeroRailsAdapter.reset_configuration!

    identity = ZeroRailsAdapter.configuration.authenticator.call(Object.new)
    assert_nil identity.user_id
    assert_nil identity.current_user
    assert_equal({}, identity.claims)
    assert ZeroRailsAdapter.configuration.request_verifier.call(Object.new)
    assert ZeroRailsAdapter.configuration.authorizer.call(Object.new, Object.new)
    assert ZeroRailsAdapter.configuration.crud_authorizer.call(
      Object.new,
      :create,
      Object.new,
      {}
    )
    assert_same ActiveRecord::Base, ZeroRailsAdapter.configuration.transaction_class
    request = Struct.new(:schema).new("zero_0")
    assert_instance_of ZeroRailsAdapter::Storage::ZeroSchema,
      ZeroRailsAdapter.configuration.storage_provider.call(request)
  end

  def test_model_provider_is_also_the_crud_allowlist
    ZeroRailsAdapter.configuration.model_provider = -> { [Article] }

    assert_same Article,
      ZeroRailsAdapter.configuration.model_resolver.call("articles")
    assert_nil ZeroRailsAdapter.configuration.model_resolver.call("books")
  end

  def test_api_key_verifier_uses_the_zero_mutate_header
    verifier = ZeroRailsAdapter::RequestVerifiers::ApiKey.new(key: "very-secret")
    valid = Struct.new(:headers).new({"X-Api-Key" => "very-secret"})
    invalid = Struct.new(:headers).new({"X-Api-Key" => "wrong"})

    assert verifier.call(valid)
    refute verifier.call(invalid)
  end

  def test_identity_normalizes_active_record_ids_for_the_zero_protocol
    identity = ZeroRailsAdapter::Identity.new(user_id: 42)

    assert_equal "42", identity.user_id
  end

  def test_define_mutator_builds_a_validated_registered_class
    mutator_class = ZeroRailsAdapter.define_mutator("math.add") do
      attribute :left, :integer
      attribute :right, :integer
      validates :left, :right, presence: true

      perform do
        {"sum" => left + right}
      end
    end

    result = mutator_class.call(
      {"left" => "2", "right" => 3},
      context: ZeroRailsAdapter::Context.new(identity: ZeroRailsAdapter::Identity.new)
    )

    assert_equal({"sum" => 5}, result)
    assert_same mutator_class, ZeroRailsAdapter.registry.fetch("math|add")
  end

  def test_registry_resolves_named_classes_again_after_a_rails_reload
    registry = ZeroRailsAdapter::Registry.new
    original = Class.new(ZeroRailsAdapter::Mutator)
    Object.const_set(:ReloadableZeroMutator, original)
    registry.register(original, as: "reloadable.run")
    Object.send(:remove_const, :ReloadableZeroMutator)
    replacement = Class.new(ZeroRailsAdapter::Mutator)
    Object.const_set(:ReloadableZeroMutator, replacement)

    assert_same replacement, registry.fetch("reloadable.run")
  ensure
    Object.send(:remove_const, :ReloadableZeroMutator) if Object.const_defined?(:ReloadableZeroMutator)
  end
end
