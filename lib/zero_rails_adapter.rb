# frozen_string_literal: true

require "rails"
require "active_record"
require "active_model"
require "active_support"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/string/inflections"
require_relative "zero_rails_adapter/version"
require_relative "zero_rails_adapter/errors"
require_relative "zero_rails_adapter/identity"
require_relative "zero_rails_adapter/context"
require_relative "zero_rails_adapter/configuration"
require_relative "zero_rails_adapter/published_schema"
require_relative "zero_rails_adapter/request_verifiers/api_key"
require_relative "zero_rails_adapter/registry"
require_relative "zero_rails_adapter/mutator"
require_relative "zero_rails_adapter/mutation"
require_relative "zero_rails_adapter/request"
require_relative "zero_rails_adapter/crud/dispatcher"
require_relative "zero_rails_adapter/type_script/generator"
require_relative "zero_rails_adapter/postgresql/publication_generator"
require_relative "zero_rails_adapter/storage/zero_schema"
require_relative "zero_rails_adapter/processor"
require_relative "zero_rails_adapter/engine"

module ZeroRailsAdapter
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    def registry
      @registry ||= Registry.new
    end

    def define_mutator(name, superclass: Mutator, &definition)
      Class.new(superclass).tap do |mutator_class|
        mutator_class.mutation_name(name)
        mutator_class.class_eval(&definition)
      end
    end
  end
end
