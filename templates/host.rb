# vv-rails host template
#
# Generates an API backend that relays LLM traffic to upstream providers,
# stores sessions and context in SQLite, and serves as a multi-device
# Action Cable hub for Vv-connected applications.
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
        resources :contexts, only: [:index, :create], controller: "contexts"
      end

      resources :providers, only: [:index, :create, :update]
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

  generate "migration", "CreateSessions user_token:string title:string metadata:json"
  generate "migration", "CreateContexts session:references role:string content:text metadata:json"
  generate "migration", "CreateProviders name:string api_base:string api_key_ciphertext:string models:json priority:integer active:boolean"
  generate "migration", "CreateApiTokens token_digest:string:index label:string expires_at:datetime"

  # --- Models ---

  file "app/models/session.rb", <<~RUBY
    class Session < ApplicationRecord
      has_many :contexts, -> { order(:created_at) }, dependent: :destroy

      validates :user_token, presence: true
      validates :title, presence: true

      def as_json(options = {})
        super(options.merge(include: options[:include] || {}, methods: []))
      end
    end
  RUBY

  file "app/models/context.rb", <<~RUBY
    class Context < ApplicationRecord
      belongs_to :session

      validates :role, inclusion: { in: %w[user assistant system] }
      validates :content, presence: true
    end
  RUBY

  file "app/models/provider.rb", <<~RUBY
    class Provider < ApplicationRecord
      validates :name, presence: true, uniqueness: true
      validates :api_base, presence: true
      validates :priority, numericality: { only_integer: true }, allow_nil: true

      scope :active, -> { where(active: true) }
      scope :by_priority, -> { order(priority: :asc) }

      def models_list
        models || []
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

        def current_user_token
          request.headers["X-User-Token"]
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
          sessions = Session.where(user_token: current_user_token).order(updated_at: :desc)
          render json: sessions
        end

        def show
          session = Session.includes(:contexts).find(params[:id])
          render json: session.as_json(include: :contexts)
        end

        def create
          session = Session.new(session_params.merge(user_token: current_user_token))
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

  # --- Contexts controller ---

  file "app/controllers/api/contexts_controller.rb", <<~RUBY
    module Api
      class ContextsController < BaseController
        def index
          session = Session.find(params[:session_id])
          render json: session.contexts
        end

        def create
          session = Session.find(params[:session_id])
          context = session.contexts.build(context_params)
          if context.save
            broadcast_context(session, context)
            render json: context, status: :created
          else
            render json: { errors: context.errors.full_messages }, status: :unprocessable_entity
          end
        end

        private

        def context_params
          params.require(:context).permit(:role, :content, metadata: {})
        end

        def broadcast_context(session, context)
          prefix = Vv::Rails.configuration.channel_prefix
          ActionCable.server.broadcast(
            "\#{prefix}:session:\#{session.id}",
            { event: "context:new", data: context.as_json }
          )
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
          render json: providers.as_json(except: :api_key_ciphertext)
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
          params.require(:provider).permit(:name, :api_base, :api_key_ciphertext, :priority, :active, models: [])
        end
      end
    end
  RUBY

  # --- Relay controller ---

  file "app/controllers/api/relay_controller.rb", <<~RUBY
    module Api
      class RelayController < BaseController
        def create
          provider = find_provider
          unless provider
            render json: { error: "No active provider available" }, status: :service_unavailable
            return
          end

          # Forward the request to the upstream provider
          # This is a scaffold — implement HTTP client calls per provider API
          render json: {
            provider: provider.name,
            model: params[:model],
            status: "relay_stub",
            message: "Implement provider-specific HTTP relay in Api::RelayController#create"
          }
        end

        private

        def find_provider
          if params[:provider].present?
            Provider.active.find_by(name: params[:provider])
          else
            Provider.active.by_priority.first
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

  # --- Seeds with a default provider ---

  append_to_file "db/seeds.rb", <<~RUBY

    # Default provider (update with real API key)
    Provider.find_or_create_by!(name: "OpenAI") do |p|
      p.api_base = "https://api.openai.com/v1"
      p.api_key_ciphertext = "sk-placeholder"
      p.models = ["gpt-4o", "gpt-4o-mini"]
      p.priority = 1
      p.active = true
    end

    Provider.find_or_create_by!(name: "Anthropic") do |p|
      p.api_base = "https://api.anthropic.com/v1"
      p.api_key_ciphertext = "sk-ant-placeholder"
      p.models = ["claude-sonnet-4-6", "claude-haiku-4-5"]
      p.priority = 2
      p.active = true
    end
  RUBY

  say ""
  say "vv-host app generated!", :green
  say "  API base:      /api"
  say "  Auth:          POST /api/auth/token"
  say "  Sessions:      /api/sessions"
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
