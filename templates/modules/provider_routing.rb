# modules/provider_routing.rb — Cost-aware provider routing per subscription tier
#
# Selects the optimal provider/model based on the user's plan tier and
# configured cost rules. Falls back to default priority-based selection
# when no routing rules match.
#
# Routing rules map plan slugs to preferred providers and cost ceilings.
# Providers are seeded with per-model cost data (cost_input_per_million,
# cost_output_per_million) which the router uses to filter and rank.
#
# Depends on: base, schema_llm, subscription, metering, api_relay, seeds_providers

after_bundle do
  # --- ProviderRouter service ---

  file "app/services/provider_router.rb", <<~RUBY
    class ProviderRouter
      # Default routing rules per plan tier.
      # Each rule defines:
      #   providers:  ordered list of preferred provider names
      #   max_input:  max cost per million input tokens (nil = no limit)
      #   max_output: max cost per million output tokens (nil = no limit)
      #   local_only: if true, only use providers that don't require an API key
      RULES = {
        "individual" => {
          providers: ["GrokCloud", "Ollama"],
          max_input: 0.10,
          max_output: 0.15
        },
        "power_user" => {
          providers: ["CompactifAI", "GrokCloud", "Anthropic", "OpenAI"],
          max_input: 0.50,
          max_output: 1.00
        },
        "group" => {
          providers: ["Ollama"],
          local_only: true
        }
      }.freeze

      # Select the best model for this subscription's tier.
      #
      # Priority:
      #   1. Explicit model_id or model param (user override — always honored)
      #   2. Tier routing rules (preferred providers + cost ceiling)
      #   3. Default priority-based selection (fallback)
      def self.select_model(subscription: nil, model_id: nil, model_name: nil)
        # User explicitly requested a model — honor it
        if model_id.present?
          return Model.active.find_by(id: model_id)
        end
        if model_name.present?
          return Model.active.find_by(api_model_id: model_name)
        end

        # No subscription = dev mode, use default priority
        return default_model unless subscription

        plan_slug = subscription.plan&.slug
        rule = RULES[plan_slug]

        # No routing rule for this tier = default priority
        return default_model unless rule

        routed_model(rule)
      end

      # Returns routing metadata for API responses
      def self.routing_info(model, subscription: nil)
        info = {
          provider: model.provider.name,
          model: model.api_model_id,
          cost_input_per_million: model.cost_input_per_million&.to_f,
          cost_output_per_million: model.cost_output_per_million&.to_f
        }
        if subscription
          info[:plan] = subscription.plan.slug
          info[:routed] = true
        end
        info
      end

      private_class_method

      def self.routed_model(rule)
        candidates = Model.active.joins(:provider).merge(Provider.active)

        # Filter by local-only if specified
        if rule[:local_only]
          candidates = candidates.where(providers: { requires_api_key: false })
        end

        # Filter by cost ceiling
        if rule[:max_input]
          candidates = candidates.where(
            "models.cost_input_per_million <= ? OR models.cost_input_per_million IS NULL",
            rule[:max_input]
          )
        end
        if rule[:max_output]
          candidates = candidates.where(
            "models.cost_output_per_million <= ? OR models.cost_output_per_million IS NULL",
            rule[:max_output]
          )
        end

        # Prefer providers in the order listed in the rule
        if rule[:providers]&.any?
          preferred = candidates.where(providers: { name: rule[:providers] })
          if preferred.exists?
            # Order by the position in the preferred list
            ordered = rule[:providers].each_with_index.map do |name, idx|
              preferred.where(providers: { name: name })
                       .order("providers.priority ASC")
            end
            model = ordered.flat_map(&:to_a).first
            return model if model
          end
        end

        # Fallback: cheapest available within cost ceiling
        candidates.order(
          Arel.sql("COALESCE(models.cost_input_per_million, 0) + COALESCE(models.cost_output_per_million, 0) ASC")
        ).first || default_model
      end

      def self.default_model
        Model.active.joins(:provider).merge(Provider.active.by_priority).first
      end
    end
  RUBY

  # --- Patch RelayController to use ProviderRouter ---

  file "app/controllers/concerns/routed.rb", <<~RUBY
    module Routed
      extend ActiveSupport::Concern

      private

      def find_routed_model
        ProviderRouter.select_model(
          subscription: respond_to?(:current_subscription, true) ? current_subscription : nil,
          model_id: params[:model_id],
          model_name: params[:model]
        )
      end
    end
  RUBY

  # Replace find_model in RelayController with routed version
  relay_path = "app/controllers/api/relay_controller.rb"
  if File.exist?(relay_path)
    gsub_file relay_path,
      "model = find_model",
      "model = find_routed_model"

    inject_into_file relay_path, after: "class RelayController < BaseController\n" do
      "        include Routed\n"
    end
  end

  # Patch AgentsController invoke to use routing when no model specified
  agents_path = "app/controllers/v1/agents_controller.rb"
  if File.exist?(agents_path)
    inject_into_file agents_path, after: "class AgentsController < Api::BaseController\n" do
      "        include Routed\n"
    end
  end

  # --- Seed GrokCloud and CompactifAI providers ---

  append_to_file "db/seeds.rb", <<~RUBY

    # --- GrokCloud (low-cost Llama inference) ---
    grokcloud = Provider.find_or_create_by!(name: "GrokCloud") do |p|
      p.api_base = "https://api.groq.com/openai/v1"
      p.api_key_ciphertext = "gsk-placeholder"
      p.priority = 1
      p.active = true
      p.requires_api_key = true
    end

    grokcloud.models.find_or_create_by!(api_model_id: "llama-3.1-8b-instant") do |m|
      m.name = "Llama 3.1 8B (GrokCloud)"
      m.context_window = 131_072
      m.capabilities = { "streaming" => true }
      m.cost_input_per_million = 0.05
      m.cost_output_per_million = 0.08
      m.active = true
    end

    grokcloud.models.find_or_create_by!(api_model_id: "llama-4-scout-17b-16e-instruct") do |m|
      m.name = "Llama 4 Scout (GrokCloud)"
      m.context_window = 131_072
      m.capabilities = { "streaming" => true }
      m.cost_input_per_million = 0.11
      m.cost_output_per_million = 0.34
      m.active = true
    end

    # --- CompactifAI (optimized Llama inference) ---
    compactifai = Provider.find_or_create_by!(name: "CompactifAI") do |p|
      p.api_base = "https://api.compactif.ai/v1"
      p.api_key_ciphertext = "cai-placeholder"
      p.priority = 2
      p.active = true
      p.requires_api_key = true
    end

    compactifai.models.find_or_create_by!(api_model_id: "llama-4-scout-compactifai") do |m|
      m.name = "Llama 4 Scout (CompactifAI)"
      m.context_window = 131_072
      m.capabilities = { "streaming" => true }
      m.cost_input_per_million = 0.11
      m.cost_output_per_million = 0.11
      m.active = true
    end
  RUBY

  # --- Add routing info to relay response ---

  if File.exist?(relay_path)
    gsub_file relay_path,
      'status: "relay_stub"',
      'status: "relay_stub",
            routing: ProviderRouter.routing_info(model, subscription: (respond_to?(:current_subscription, true) ? current_subscription : nil))'
  end
end
