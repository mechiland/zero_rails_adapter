# frozen_string_literal: true

module ZeroRailsAdapter
  class ClientMutation < ActiveRecord::Base
    self.table_name = "zero_rails_adapter_client_mutations"

    validates :app_id, :schema_name, :client_group_id, :client_id, presence: true
    validates :last_mutation_id, numericality: {only_integer: true, greater_than_or_equal_to: 0}
  end

  class MutationResult < ActiveRecord::Base
    self.table_name = "zero_rails_adapter_mutation_results"

    validates :app_id, :schema_name, :client_group_id, :client_id, :result, presence: true
    validates :mutation_id, numericality: {only_integer: true, greater_than: 0}
  end

  module Storage
    class RailsTables
      attr_reader :request, :transaction_class

      def initialize(request:, transaction_class:)
        @request = request
        @transaction_class = transaction_class
      end

      def transaction(&block)
        transaction_class.transaction(requires_new: true, &block)
      end

      def increment_lmid!(client_id)
        attributes = identity_attributes(client_id)
        record = ClientMutation.create_or_find_by!(attributes) do |client|
          client.last_mutation_id = 1
        end
        created = record.previously_new_record?
        record.lock!
        record.update!(last_mutation_id: record.last_mutation_id + 1) unless created
        record.last_mutation_id
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      def write_result(client_id:, mutation_id:, result:)
        MutationResult.create!(
          **identity_attributes(client_id),
          mutation_id:,
          result:
        )
      end

      def cleanup(args)
        scope = MutationResult.where(
          app_id: request.app_id,
          schema_name: request.schema,
          client_group_id: args["clientGroupID"]
        )

        if args["type"] == "bulk"
          scope.where(client_id: Array(args["clientIDs"])).delete_all
        elsif args["clientID"].is_a?(String) && args["upToMutationID"].is_a?(Numeric)
          scope.where(client_id: args["clientID"])
            .where("mutation_id <= ?", args["upToMutationID"])
            .delete_all
        end
      end

      private

      def identity_attributes(client_id)
        {
          app_id: request.app_id,
          schema_name: request.schema,
          client_group_id: request.client_group_id,
          client_id:
        }
      end
    end
  end
end
