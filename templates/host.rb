# vv-rails host template
#
# Generates an API backend that relays LLM traffic to upstream providers,
# stores sessions, messages, turns, and presets in SQLite, and serves as
# a multi-device Action Cable hub for Vv-connected applications.
#
# Usage:
#   rails new myapp -m vendor/vv-rails/templates/host.rb
#

# --- Gems ---

gem "vv-rails", path: "vendor/vv-rails"
gem "bcrypt", "~> 3.1"

# --- vv:install (inlined — creates initializer and mounts engine) ---

initializer "vv_rails.rb", <<~RUBY
  Vv::Rails.configure do |config|
    config.channel_prefix = "vv"
    # config.cable_url = "ws://localhost:3000/cable"
    # config.authenticate = ->(params) { User.find_by(token: params[:token]) }
  end
RUBY

after_bundle do
  # --- Vv logo ---
  logo_src = File.join(File.dirname(__FILE__), "vv-logo.png")
  copy_file logo_src, "public/vv-logo.png" if File.exist?(logo_src)

  # --- Routes (engine auto-mounts at /vv via initializer) ---

  route <<~RUBY
    root "home#index"

    namespace :api do
      post "auth/token", to: "auth#token"

      resources :sessions, only: [:index, :show, :create, :destroy] do
        resources :messages, only: [:index, :create]
        resources :turns, only: [:index, :show]
      end

      resources :providers, only: [:index, :show, :create, :update] do
        resources :models, only: [:index, :create, :update]
      end

      resources :models, only: [:index, :show] do
        resources :presets, only: [:index, :create, :update, :destroy]
      end

      post "relay", to: "relay#create"
    end
  RUBY

  # --- HomeController ---

  file "app/controllers/home_controller.rb", <<~RUBY
    class HomeController < ApplicationController
      def index
      end
    end
  RUBY

  # --- Layout with Vv logo ---

  remove_file "app/views/layouts/application.html.erb"
  file "app/views/layouts/application.html.erb", <<~'ERB'
    <!DOCTYPE html>
    <html>
      <head>
        <title><%= content_for(:title) || "Vv Host" %></title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="icon" href="/icon.png" type="image/png">
        <%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
        <%= javascript_importmap_tags %>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; background: #f5f5f5; color: #333; }
          .vv-header { background: #1a1a2e; padding: 12px 24px; display: flex; align-items: center; }
          .vv-header__logo { height: 40px; }
          .vv-main { max-width: 800px; margin: 0 auto; padding: 24px; }
        </style>
      </head>
      <body>
        <header class="vv-header">
          <a href="/"><img src="/vv-logo.png" alt="Vv" class="vv-header__logo"></a>
        </header>
        <main class="vv-main">
          <%= yield %>
        </main>
      </body>
    </html>
  ERB

  # --- Home page view ---

  file "app/views/home/index.html.erb", <<~'ERB'
    <div style="text-align: center; padding: 60px 20px;">
      <img src="/vv-logo.png" alt="Vv" style="max-width: 400px; width: 100%; margin-bottom: 24px;">
      <h1 style="font-size: 24px; color: #1a1a2e; margin-bottom: 8px;">Vv Host</h1>
      <p style="color: #666;">LLM relay API backend</p>
      <p style="margin-top: 24px; font-size: 14px; color: #999;">API base: <code>/api</code> &middot; Plugin config: <code>/vv/config.json</code></p>
    </div>
  ERB

  # --- Migrations ---

  generate "migration", "CreateSessions title:string metadata:json"
  generate "migration", "CreateProviders name:string api_base:string api_key_ciphertext:string priority:integer active:boolean requires_api_key:boolean"
  generate "migration", "CreateModels provider:references name:string api_model_id:string context_window:integer capabilities:json active:boolean"
  generate "migration", "CreatePresets model:references name:string temperature:float max_tokens:integer system_prompt:text top_p:float parameters:json active:boolean"
  generate "migration", "CreateMessages session:references role:string message_type:string content:text metadata:json"
  generate "migration", "CreateTurns session:references model:references preset:references message_history:json request:text completion:text input_tokens:integer output_tokens:integer duration_ms:integer"
  generate "migration", "CreateApiTokens token_digest:string:index label:string expires_at:datetime"

  # --- Models ---

  file "app/models/session.rb", <<~RUBY
    class Session < ApplicationRecord
      has_many :messages, -> { order(:created_at) }, dependent: :destroy
      has_many :turns, -> { order(:created_at) }, dependent: :destroy

      validates :title, presence: true

      def as_json(options = {})
        super(options.merge(include: options[:include] || {}, methods: []))
      end
    end
  RUBY

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

  file "app/models/message.rb", <<~RUBY
    class Message < ApplicationRecord
      belongs_to :session

      ROLES = %w[user assistant system].freeze
      MESSAGE_TYPES = %w[user_input navigation data_query form_state].freeze

      validates :role, inclusion: { in: ROLES }
      validates :message_type, inclusion: { in: MESSAGE_TYPES }
      validates :content, presence: true
    end
  RUBY

  file "app/models/turn.rb", <<~RUBY
    class Turn < ApplicationRecord
      belongs_to :session
      belongs_to :model
      belongs_to :preset, optional: true

      validates :message_history, presence: true
      validates :request, presence: true

      def token_count
        (input_tokens || 0) + (output_tokens || 0)
      end
    end
  RUBY

  file "app/models/api_token.rb", <<~RUBY
    class ApiToken < ApplicationRecord
      attr_accessor :raw_token

      def self.generate
        token = ApiToken.new
        token.raw_token = SecureRandom.hex(32)
        token.token_digest = BCrypt::Password.create(token.raw_token)
        token
      end

      def self.authenticate(raw_token)
        return nil if raw_token.blank?
        find_each do |api_token|
          return api_token if BCrypt::Password.new(api_token.token_digest) == raw_token
        end
        nil
      end
    end
  RUBY

  # --- Base API controller with token auth ---

  file "app/controllers/api/base_controller.rb", <<~RUBY
    module Api
      class BaseController < ActionController::API
        before_action :authenticate_token!

        private

        def authenticate_token!
          token = request.headers["Authorization"]&.delete_prefix("Bearer ")
          unless token && ApiToken.authenticate(token)
            render json: { error: "Unauthorized" }, status: :unauthorized
          end
        end
      end
    end
  RUBY

  # --- Auth controller (token issuance) ---

  file "app/controllers/api/auth_controller.rb", <<~RUBY
    module Api
      class AuthController < ActionController::API
        def token
          api_token = ApiToken.generate
          if api_token.save
            render json: { token: api_token.raw_token, label: api_token.label }
          else
            render json: { error: "Failed to create token" }, status: :unprocessable_entity
          end
        end
      end
    end
  RUBY

  # --- Sessions controller ---

  file "app/controllers/api/sessions_controller.rb", <<~RUBY
    module Api
      class SessionsController < BaseController
        def index
          sessions = Session.order(updated_at: :desc)
          render json: sessions
        end

        def show
          session = Session.includes(:messages, :turns).find(params[:id])
          render json: session.as_json(include: [:messages, :turns])
        end

        def create
          session = Session.new(session_params)
          if session.save
            render json: session, status: :created
          else
            render json: { errors: session.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          session = Session.find(params[:id])
          session.destroy
          head :no_content
        end

        private

        def session_params
          params.require(:session).permit(:title, metadata: {})
        end
      end
    end
  RUBY

  # --- Messages controller ---

  file "app/controllers/api/messages_controller.rb", <<~RUBY
    module Api
      class MessagesController < BaseController
        def index
          session = Session.find(params[:session_id])
          render json: session.messages
        end

        def create
          session = Session.find(params[:session_id])
          message = session.messages.build(message_params)
          if message.save
            broadcast_message(session, message)
            render json: message, status: :created
          else
            render json: { errors: message.errors.full_messages }, status: :unprocessable_entity
          end
        end

        private

        def message_params
          params.require(:message).permit(:role, :message_type, :content, metadata: {})
        end

        def broadcast_message(session, message)
          prefix = Vv::Rails.configuration.channel_prefix
          ActionCable.server.broadcast(
            "\#{prefix}:session:\#{session.id}",
            { event: "message:new", data: message.as_json }
          )
        end
      end
    end
  RUBY

  # --- Turns controller (read-only — turns created by relay) ---

  file "app/controllers/api/turns_controller.rb", <<~RUBY
    module Api
      class TurnsController < BaseController
        def index
          session = Session.find(params[:session_id])
          render json: session.turns.as_json(include: [:model, :preset])
        end

        def show
          session = Session.find(params[:session_id])
          turn = session.turns.find(params[:id])
          render json: turn.as_json(include: [:model, :preset])
        end
      end
    end
  RUBY

  # --- Providers controller ---

  file "app/controllers/api/providers_controller.rb", <<~RUBY
    module Api
      class ProvidersController < BaseController
        def index
          providers = Provider.active.by_priority
          render json: providers.as_json(except: :api_key_ciphertext, include: :models)
        end

        def show
          provider = Provider.find(params[:id])
          render json: provider.as_json(except: :api_key_ciphertext, include: { models: { include: :presets } })
        end

        def create
          provider = Provider.new(provider_params)
          if provider.save
            render json: provider.as_json(except: :api_key_ciphertext), status: :created
          else
            render json: { errors: provider.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          provider = Provider.find(params[:id])
          if provider.update(provider_params)
            render json: provider.as_json(except: :api_key_ciphertext)
          else
            render json: { errors: provider.errors.full_messages }, status: :unprocessable_entity
          end
        end

        private

        def provider_params
          params.require(:provider).permit(:name, :api_base, :api_key_ciphertext, :priority, :active, :requires_api_key)
        end
      end
    end
  RUBY

  # --- Models controller ---

  file "app/controllers/api/models_controller.rb", <<~RUBY
    module Api
      class ModelsController < BaseController
        def index
          models = if params[:provider_id]
            Provider.find(params[:provider_id]).models.active
          else
            Model.active.includes(:provider)
          end
          render json: models.as_json(include: :provider)
        end

        def show
          model = Model.find(params[:id])
          render json: model.as_json(include: [:provider, :presets])
        end

        def create
          provider = Provider.find(params[:provider_id])
          model = provider.models.build(model_params)
          if model.save
            render json: model, status: :created
          else
            render json: { errors: model.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          model = Model.find(params[:id])
          if model.update(model_params)
            render json: model
          else
            render json: { errors: model.errors.full_messages }, status: :unprocessable_entity
          end
        end

        private

        def model_params
          params.require(:model).permit(:name, :api_model_id, :context_window, :active, capabilities: {})
        end
      end
    end
  RUBY

  # --- Presets controller ---

  file "app/controllers/api/presets_controller.rb", <<~RUBY
    module Api
      class PresetsController < BaseController
        def index
          model = Model.find(params[:model_id])
          render json: model.presets.active
        end

        def create
          model = Model.find(params[:model_id])
          preset = model.presets.build(preset_params)
          if preset.save
            render json: preset, status: :created
          else
            render json: { errors: preset.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          preset = Preset.find(params[:id])
          if preset.update(preset_params)
            render json: preset
          else
            render json: { errors: preset.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          preset = Preset.find(params[:id])
          preset.destroy
          head :no_content
        end

        private

        def preset_params
          params.require(:preset).permit(:name, :temperature, :max_tokens, :system_prompt, :top_p, :active, parameters: {})
        end
      end
    end
  RUBY

  # --- Relay controller ---

  file "app/controllers/api/relay_controller.rb", <<~RUBY
    module Api
      class RelayController < BaseController
        def create
          model = find_model
          unless model
            render json: { error: "No active model available" }, status: :service_unavailable
            return
          end

          preset = params[:preset_id] ? Preset.find(params[:preset_id]) : nil
          session = params[:session_id] ? Session.find(params[:session_id]) : nil

          # Build message history snapshot from session messages
          message_history = session ? session.messages.order(:created_at).as_json(only: [:role, :message_type, :content]) : []

          # Create turn record
          turn = Turn.new(
            session: session,
            model: model,
            preset: preset,
            message_history: message_history,
            request: params[:content]
          )

          # Forward the request to the upstream provider
          # This is a scaffold — implement HTTP client calls per provider API
          turn.completion = "Implement provider-specific HTTP relay in Api::RelayController#create"
          turn.save!

          render json: {
            turn_id: turn.id,
            provider: model.provider.name,
            model: model.api_model_id,
            preset: preset&.name,
            status: "relay_stub",
            message: turn.completion
          }
        end

        private

        def find_model
          if params[:model_id].present?
            Model.active.find_by(id: params[:model_id])
          elsif params[:model].present?
            Model.active.find_by(api_model_id: params[:model])
          else
            Model.active.joins(:provider).merge(Provider.active.by_priority).first
          end
        end
      end
    end
  RUBY

  # --- Action Cable base classes ---

  file "app/channels/application_cable/connection.rb", <<~RUBY
    module ApplicationCable
      class Connection < ActionCable::Connection::Base
      end
    end
  RUBY

  file "app/channels/application_cable/channel.rb", <<~RUBY
    module ApplicationCable
      class Channel < ActionCable::Channel::Base
      end
    end
  RUBY

  # --- VvRelayChannel for multi-device sync ---

  file "app/channels/vv_relay_channel.rb", <<~RUBY
    class VvRelayChannel < ApplicationCable::Channel
      def subscribed
        session_id = params[:session_id]
        return reject unless session_id

        prefix = Vv::Rails.configuration.channel_prefix
        stream_from "\#{prefix}:session:\#{session_id}"
      end

      def receive(data)
        session_id = params[:session_id]
        prefix = Vv::Rails.configuration.channel_prefix

        # Relay to all subscribers of this session
        ActionCable.server.broadcast(
          "\#{prefix}:session:\#{session_id}",
          data
        )
      end
    end
  RUBY

  # --- Seeds with providers, models, and presets ---

  append_to_file "db/seeds.rb", <<~RUBY

    # --- OpenAI ---
    openai = Provider.find_or_create_by!(name: "OpenAI") do |p|
      p.api_base = "https://api.openai.com/v1"
      p.api_key_ciphertext = "sk-placeholder"
      p.priority = 1
      p.active = true
      p.requires_api_key = true
    end

    gpt4o = openai.models.find_or_create_by!(api_model_id: "gpt-4o") do |m|
      m.name = "GPT-4o"
      m.context_window = 128_000
      m.capabilities = { "vision" => true, "function_calling" => true, "streaming" => true }
      m.active = true
    end

    gpt4o.presets.find_or_create_by!(name: "default") do |p|
      p.temperature = 0.7
      p.max_tokens = 4096
      p.system_prompt = "You are a helpful assistant."
      p.active = true
    end

    openai.models.find_or_create_by!(api_model_id: "gpt-4o-mini") do |m|
      m.name = "GPT-4o Mini"
      m.context_window = 128_000
      m.capabilities = { "function_calling" => true, "streaming" => true }
      m.active = true
    end

    # --- Anthropic ---
    anthropic = Provider.find_or_create_by!(name: "Anthropic") do |p|
      p.api_base = "https://api.anthropic.com/v1"
      p.api_key_ciphertext = "sk-ant-placeholder"
      p.priority = 2
      p.active = true
      p.requires_api_key = true
    end

    claude_sonnet = anthropic.models.find_or_create_by!(api_model_id: "claude-sonnet-4-6") do |m|
      m.name = "Claude Sonnet 4.6"
      m.context_window = 200_000
      m.capabilities = { "vision" => true, "streaming" => true }
      m.active = true
    end

    claude_sonnet.presets.find_or_create_by!(name: "default") do |p|
      p.temperature = 0.7
      p.max_tokens = 4096
      p.system_prompt = "You are a helpful assistant."
      p.active = true
    end

    anthropic.models.find_or_create_by!(api_model_id: "claude-haiku-4-5") do |m|
      m.name = "Claude Haiku 4.5"
      m.context_window = 200_000
      m.capabilities = { "streaming" => true }
      m.active = true
    end

    # --- Ollama (local, no API key) ---
    ollama = Provider.find_or_create_by!(name: "Ollama") do |p|
      p.api_base = "http://localhost:11434"
      p.api_key_ciphertext = nil
      p.priority = 3
      p.active = false
      p.requires_api_key = false
    end

    ollama.models.find_or_create_by!(api_model_id: "llama3.1") do |m|
      m.name = "Llama 3.1"
      m.context_window = 128_000
      m.capabilities = { "streaming" => true }
      m.active = true
    end
  RUBY

  say ""
  say "vv-host app generated!", :green
  say "  API base:      /api"
  say "  Auth:          POST /api/auth/token"
  say "  Sessions:      /api/sessions"
  say "  Messages:      /api/sessions/:id/messages"
  say "  Turns:         /api/sessions/:id/turns"
  say "  Providers:     /api/providers"
  say "  Models:        /api/models"
  say "  Presets:       /api/models/:id/presets"
  say "  Relay:         POST /api/relay"
  say "  Plugin config: GET /vv/config.json"
  say ""
  say "Next steps:"
  say "  1. rails db:create db:migrate db:seed"
  say "  2. Update provider API keys in seeds or via API"
  say "  3. Implement relay HTTP client in Api::RelayController"
  say "  4. rails server"
  say ""
end
