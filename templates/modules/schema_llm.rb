# modules/schema_llm.rb — Provider, Model, Preset tables + ActiveRecord models
#
# Depends on: base

after_bundle do
  generate "migration", "CreateProviders name:string api_base:string api_key_ciphertext:string priority:integer active:boolean requires_api_key:boolean"
  generate "migration", "CreateModels provider:references name:string api_model_id:string context_window:integer capabilities:json active:boolean cost_input_per_million:decimal cost_output_per_million:decimal"
  generate "migration", "CreatePresets model:references name:string temperature:float max_tokens:integer system_prompt:text top_p:float parameters:json active:boolean"

  file "app/models/provider.rb", <<~RUBY
    class Provider < ApplicationRecord
      has_many :models, dependent: :destroy

      validates :name, presence: true, uniqueness: true
      validates :api_base, presence: true
      validates :priority, numericality: { only_integer: true }, allow_nil: true

      scope :active, -> { where(active: true) }
      scope :by_priority, -> { order(priority: :asc) }

      def requires_key?
        requires_api_key != false
      end
    end
  RUBY

  file "app/models/model.rb", <<~RUBY
    class Model < ApplicationRecord
      belongs_to :provider
      has_many :presets, dependent: :destroy
      has_many :turns

      validates :name, presence: true
      validates :api_model_id, presence: true
      validates :api_model_id, uniqueness: { scope: :provider_id }

      scope :active, -> { where(active: true) }

      def capabilities_list
        capabilities || {}
      end

      def supports?(capability)
        capabilities_list[capability.to_s] == true
      end

      def has_cost?
        cost_input_per_million.present? || cost_output_per_million.present?
      end

      def cost_for(input_tokens, output_tokens)
        input_cost = (input_tokens.to_f / 1_000_000) * (cost_input_per_million || 0)
        output_cost = (output_tokens.to_f / 1_000_000) * (cost_output_per_million || 0)
        input_cost + output_cost
      end
    end
  RUBY

  file "app/models/preset.rb", <<~RUBY
    class Preset < ApplicationRecord
      belongs_to :model

      validates :name, presence: true
      validates :name, uniqueness: { scope: :model_id }
      validates :temperature, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 2 }, allow_nil: true
      validates :top_p, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
      validates :max_tokens, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

      scope :active, -> { where(active: true) }

      def to_inference_params
        params = {}
        params[:temperature] = temperature if temperature
        params[:max_tokens] = max_tokens if max_tokens
        params[:top_p] = top_p if top_p
        params.merge((parameters || {}).symbolize_keys)
      end
    end
  RUBY
end
