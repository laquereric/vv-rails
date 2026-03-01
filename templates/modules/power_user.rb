# modules/power_user.rb — Agent publishing + Power User plan activation
#
# Provides: Agent model, AgentPolicy, AgentsController with /v1/agents routes,
# invoke endpoint (delegates to relay logic), Power User plan seed updates.
#
# Depends on: base, schema_llm, schema_session, auth_token, subscription,
#             metering, auth_user, authorization, api_rest

after_bundle do
  # --- Migrations ---

  generate "migration", "CreateAgents user:references model:references preset:references name:string slug:string:uniq description:text system_prompt:text active:boolean public:boolean"

  # Set defaults on agents migration
  agents_migration = Dir.glob("db/migrate/*_create_agents.rb").first
  if agents_migration
    gsub_file agents_migration, "t.boolean :active", "t.boolean :active, default: true"
    gsub_file agents_migration, "t.boolean :public", "t.boolean :public, default: false"
    # Make user_id nullable (system agents have no owner)
    gsub_file agents_migration, "null: false", "null: true"
  end

  # --- Agent model ---

  file "app/models/agent.rb", <<~RUBY
    class Agent < ApplicationRecord
      belongs_to :user, optional: true
      belongs_to :model
      belongs_to :preset, optional: true

      validates :name, presence: true, uniqueness: { scope: :user_id }
      validates :slug, presence: true, uniqueness: true,
                       format: { with: /\\A[a-z0-9][a-z0-9_-]*\\z/, message: "must be lowercase alphanumeric with dashes/underscores" }
      validates :system_prompt, presence: true

      scope :active, -> { where(active: true) }
      scope :public_agents, -> { where(public: true) }

      before_validation :generate_slug, on: :create

      def owned_by?(check_user)
        user_id == check_user&.id
      end

      def to_inference_config
        config = { model_id: model_id, system_prompt: system_prompt }
        config[:preset_id] = preset_id if preset_id
        config
      end

      private

      def generate_slug
        return if slug.present?
        base = name&.parameterize
        self.slug = base
      end
    end
  RUBY

  # --- Add agents association to User model ---

  inject_into_file "app/models/user.rb", after: "has_many :api_tokens, dependent: :destroy\n" do
    "  has_many :agents, dependent: :destroy\n"
  end

  # --- AgentPolicy ---

  file "app/policies/agent_policy.rb", <<~RUBY
    class AgentPolicy < ApplicationPolicy
      def index?;   true end
      def show?;    admin? || owner? || record.public? end
      def create?;  true end
      def update?;  admin? || owner? end
      def destroy?; admin? || owner? end
      def invoke?;  admin? || owner? || record.public? end

      class Scope < ApplicationPolicy::Scope
        def resolve
          if user&.role == "admin"
            model.all
          else
            model.where(user_id: user&.id)
                 .or(model.where(public: true, active: true))
          end
        end
      end
    end
  RUBY

  # --- AgentsController ---

  file "app/controllers/v1/agents_controller.rb", <<~RUBY
    module V1
      class AgentsController < Api::BaseController
        include Metered

        before_action :set_agent, only: [:show, :update, :destroy, :invoke]

        def index
          agents = scope(Agent).order(created_at: :desc)
          render json: agents.as_json(include: [:model], methods: [:owned_by_current_user])
        end

        def show
          authorize!(@agent, :show)
          render json: @agent.as_json(include: [:model, :preset])
        end

        def create
          @agent = Agent.new(agent_params)
          @agent.user_id = current_user&.id
          authorize!(@agent, :create)

          if @agent.save
            render json: @agent.as_json(include: [:model, :preset]), status: :created
          else
            render json: { errors: @agent.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          authorize!(@agent, :update)

          if @agent.update(agent_params)
            render json: @agent.as_json(include: [:model, :preset])
          else
            render json: { errors: @agent.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          authorize!(@agent, :destroy)
          @agent.destroy
          head :no_content
        end

        def invoke
          authorize!(@agent, :invoke)

          # Build inference request from agent config
          model = @agent.model
          unless model&.active?
            render json: { error: "Agent's model is not available" }, status: :service_unavailable
            return
          end

          preset = @agent.preset
          session = params[:session_id] ? Session.find(params[:session_id]) : nil

          message_history = session ? session.messages_from_events : []

          # Prepend agent's system prompt as first message
          system_message = { role: "system", content: @agent.system_prompt }

          turn = Turn.new(
            session: session,
            model: model,
            preset: preset,
            message_history: [system_message] + message_history,
            request: params[:content]
          )

          # Scaffold — implement HTTP client calls per provider API
          turn.completion = "Implement provider-specific HTTP relay in V1::AgentsController#invoke"
          turn.save!

          # Record metered usage with model for credit-based billing
          record_token_usage(
            turn.input_tokens.to_i,
            turn.output_tokens.to_i,
            model: model
          )

          render json: {
            turn_id: turn.id,
            agent: @agent.slug,
            provider: model.provider.name,
            model: model.api_model_id,
            preset: preset&.name,
            status: "relay_stub",
            message: turn.completion
          }
        end

        private

        def set_agent
          @agent = Agent.find(params[:id])
        end

        def agent_params
          params.require(:agent).permit(:name, :slug, :model_id, :preset_id, :system_prompt, :description, :active, :public)
        end
      end
    end
  RUBY

  # Add JSON helper to Agent for index serialization
  inject_into_file "app/models/agent.rb", before: "\n      private" do
    <<~RUBY

      def owned_by_current_user
        # Set by controller context — default false for serialization
        @owned_by_current_user || false
      end

      attr_writer :owned_by_current_user
    RUBY
  end

  # --- Routes ---

  route <<~RUBY
    namespace :v1 do
      resources :agents, only: [:index, :show, :create, :update, :destroy] do
        member do
          post :invoke
        end
      end
    end
  RUBY
end
