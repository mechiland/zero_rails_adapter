# frozen_string_literal: true

module ZeroRailsAdapter
  module Storage
    class ZeroSchema
      class << self
        def model(base_class:, table_name:, primary_key:)
          key = [base_class, table_name, primary_key]
          models_mutex.synchronize do
            models[key] ||= Class.new(base_class) do
              self.table_name = table_name
              self.primary_key = primary_key
              self.inheritance_column = :_zero_rails_adapter_type
            end
          end
        end

        private

        def models
          @models ||= {}
        end

        def models_mutex
          @models_mutex ||= Mutex.new
        end
      end

      attr_reader :request, :transaction_class, :client_model,
        :mutation_result_model

      def initialize(request:, transaction_class:)
        @request = request
        @transaction_class = transaction_class
        @client_model = self.class.model(
          base_class: transaction_class,
          table_name: "#{request.schema}.clients",
          primary_key: %w[clientGroupID clientID]
        )
        @mutation_result_model = self.class.model(
          base_class: transaction_class,
          table_name: "#{request.schema}.mutations",
          primary_key: %w[clientGroupID clientID mutationID]
        )
      end

      def transaction(&block)
        transaction_class.transaction(requires_new: true, &block)
      end

      def increment_lmid!(client_id)
        attributes = client_identity(client_id)
        record = client_model.create_or_find_by!(attributes) do |client|
          client["lastMutationID"] = 1
        end
        created = record.previously_new_record?
        record.lock!
        record.update!("lastMutationID" => record["lastMutationID"].to_i + 1) unless created
        record["lastMutationID"].to_i
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      def write_result(client_id:, mutation_id:, result:)
        mutation_result_model.create!(
          "clientGroupID" => request.client_group_id,
          "clientID" => client_id,
          "mutationID" => mutation_id,
          "result" => result
        )
      end

      def cleanup(args)
        scope = mutation_result_model.where("clientGroupID" => args["clientGroupID"])

        if args["type"] == "bulk"
          scope.where("clientID" => Array(args["clientIDs"])).delete_all
        elsif args["clientID"].is_a?(String) && args["upToMutationID"].is_a?(Numeric)
          scope.where("clientID" => args["clientID"])
            .where('"mutationID" <= ?', args["upToMutationID"])
            .delete_all
        end
      end

      private

      def client_identity(client_id)
        {
          "clientGroupID" => request.client_group_id,
          "clientID" => client_id
        }
      end
    end
  end
end
