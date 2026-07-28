# frozen_string_literal: true

module ZeroRailsAdapter
  class Registry
    SEPARATOR = /[|.]/

    def initialize
      @mutators = {}
    end

    def register(mutator_class, as: mutator_class.mutation_name)
      raise ArgumentError, "mutation_name must be configured" if as.to_s.empty?

      @mutators[canonical(as)] = mutator_class.name.to_s.empty? ? mutator_class : mutator_class.name
      mutator_class
    end

    def fetch(name)
      find(name) || raise(UnknownMutatorError, "Could not find mutator #{name}")
    end

    def find(name)
      key = canonical(name)
      mutator = resolve(@mutators[key])
      return mutator if mutator

      conventional_class_name(name).safe_constantize
      mutator = resolve(@mutators[key])
      return mutator if mutator
    end

    def registered_names
      @mutators.keys.sort
    end

    private

    def canonical(name)
      name.to_s.split(SEPARATOR).join("|")
    end

    def conventional_class_name(name)
      parts = name.to_s.split(SEPARATOR)
      "#{parts.map(&:camelize).join('::')}Mutator"
    end

    def resolve(entry)
      entry.is_a?(String) ? entry.safe_constantize : entry
    end
  end
end
