# modules/authorization.rb — Role-based authorization (owner/admin/member)
#
# Provides: role column on users, user_id on sessions/presets,
# Authorization concern, ApplicationPolicy base class,
# SessionPolicy, ProviderPolicy, PresetPolicy, admin seed.
#
# Depends on: base, auth_token, subscription, metering, auth_user


@vv_applied_modules ||= []; @vv_applied_modules << "authorization"

after_bundle do
  # --- Migrations ---

  generate "migration", "AddRoleToUsers role:string"

  # Set default on role migration
  role_migration = Dir.glob("db/migrate/*_add_role_to_users.rb").last
  if role_migration
    gsub_file role_migration,
      'add_column :users, :role, :string',
      'add_column :users, :role, :string, default: "member"'
  end

  generate "migration", "AddUserToSessions user:references"

  # Make user_id nullable on sessions (API-created sessions may not have a user)
  sessions_migration = Dir.glob("db/migrate/*_add_user_to_sessions.rb").last
  if sessions_migration
    gsub_file sessions_migration, "null: false", "null: true"
  end

  generate "migration", "AddUserToPresets user:references"

  # Make user_id nullable on presets (system/seeded presets have no owner)
  presets_migration = Dir.glob("db/migrate/*_add_user_to_presets.rb").last
  if presets_migration
    gsub_file presets_migration, "null: false", "null: true"
  end

  # --- Authorization concern ---

  file "app/controllers/concerns/authorization.rb", <<~'RUBY'
    module Authorization
      extend ActiveSupport::Concern

      class NotAuthorizedError < StandardError; end

      included do
        rescue_from NotAuthorizedError do |e|
          respond_to do |format|
            format.json { render json: { error: "Forbidden" }, status: :forbidden }
            format.html { redirect_to root_path, alert: "Not authorized" }
          end
        end
      end

      private

      def authorize!(record, action = nil)
        action ||= action_name.to_sym
        unless policy(record).public_send(:"#{action}?")
          raise NotAuthorizedError
        end
      end

      def policy(record)
        klass = "#{record.is_a?(Class) ? record : record.class}Policy"
        klass.constantize.new(current_user, record)
      end

      def scope(model_class)
        "#{model_class}Policy::Scope".constantize.new(current_user, model_class).resolve
      end
    end
  RUBY

  # --- ApplicationPolicy base ---

  file "app/policies/application_policy.rb", <<~RUBY
    class ApplicationPolicy
      attr_reader :user, :record

      def initialize(user, record)
        @user = user
        @record = record
      end

      def admin?
        user&.role == "admin"
      end

      def owner?
        record.respond_to?(:user_id) && record.user_id == user&.id
      end

      def index?;   false end
      def show?;    false end
      def create?;  false end
      def update?;  false end
      def destroy?; false end

      class Scope
        attr_reader :user, :model

        def initialize(user, model)
          @user = user
          @model = model
        end

        def resolve
          model.all
        end
      end
    end
  RUBY

  # --- SessionPolicy ---

  file "app/policies/session_policy.rb", <<~RUBY
    class SessionPolicy < ApplicationPolicy
      def index?;   true end
      def show?;    admin? || owner? end
      def create?;  true end
      def update?;  admin? || owner? end
      def destroy?; admin? || owner? end

      class Scope < ApplicationPolicy::Scope
        def resolve
          if user&.role == "admin"
            model.all
          else
            model.where(user_id: user&.id)
          end
        end
      end
    end
  RUBY

  # --- ProviderPolicy ---

  file "app/policies/provider_policy.rb", <<~RUBY
    class ProviderPolicy < ApplicationPolicy
      def index?;   true end
      def show?;    true end
      def create?;  admin? end
      def update?;  admin? end
      def destroy?; admin? end

      class Scope < ApplicationPolicy::Scope
        def resolve
          if user&.role == "admin"
            model.all
          else
            model.where(active: true)
          end
        end
      end
    end
  RUBY

  # --- PresetPolicy ---

  file "app/policies/preset_policy.rb", <<~RUBY
    class PresetPolicy < ApplicationPolicy
      def index?;   true end
      def show?;    true end
      def create?;  true end
      def update?;  admin? || owner? end
      def destroy?; admin? || owner? end

      class Scope < ApplicationPolicy::Scope
        def resolve
          if user&.role == "admin"
            model.all
          else
            model.where(user_id: [user&.id, nil]).or(model.where(active: true))
          end
        end
      end
    end
  RUBY

  # --- Update Api::BaseController to include Authorization ---

  file "app/controllers/api/base_controller.rb", <<~RUBY
    module Api
      class BaseController < ActionController::API
        include Authorization

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

  # --- Update SessionsController with authorization ---

  file "app/controllers/api/sessions_controller.rb", <<~RUBY
    module Api
      class SessionsController < BaseController
        def index
          sessions = scope(Session).order(updated_at: :desc)
          render json: sessions
        end

        def show
          session_record = Session.find(params[:id])
          authorize!(session_record, :show)
          render json: session_record.as_json(include: [:turns]).merge(
            events: session_record.events.map { |e|
              { event_id: e.event_id, event_type: e.event_type, data: e.data, timestamp: e.metadata[:timestamp] }
            }
          )
        end

        def create
          session_record = Session.new(session_params)
          session_record.user_id = current_user&.id
          authorize!(session_record, :create)
          if session_record.save
            render json: session_record, status: :created
          else
            render json: { errors: session_record.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          session_record = Session.find(params[:id])
          authorize!(session_record, :destroy)
          session_record.destroy
          head :no_content
        end

        private

        def session_params
          params.require(:session).permit(:title, metadata: {})
        end
      end
    end
  RUBY

  # --- Update EventsController with session ownership check ---

  file "app/controllers/api/events_controller.rb", <<~RUBY
    module Api
      class EventsController < BaseController
        before_action :set_session

        def index
          render json: @session_record.events.map { |e| event_json(e) }
        end

        def create
          event_class = Vv::Rails::Events.for(params[:message_type])
          unless event_class
            render json: { error: "Unknown message_type: \#{params[:message_type]}" }, status: :unprocessable_entity
            return
          end

          event = event_class.new(data: {
            role: params[:role],
            content: params[:content],
            **(params[:metadata]&.permit!&.to_h || {})
          })
          Rails.configuration.event_store.publish(event, stream_name: "session:\#{@session_record.id}")

          broadcast_event(@session_record, event)
          render json: event_json(event), status: :created
        end

        private

        def set_session
          @session_record = Session.find(params[:session_id])
          authorize!(@session_record, :show)
        end

        def event_json(e)
          { event_id: e.event_id, event_type: e.event_type, data: e.data, timestamp: e.metadata[:timestamp] }
        end

        def broadcast_event(session_record, event)
          prefix = Vv::Rails.configuration.channel_prefix
          ActionCable.server.broadcast(
            "\#{prefix}:session:\#{session_record.id}",
            { event: "event:new", data: event_json(event) }
          )
        end
      end
    end
  RUBY

  # --- Update TurnsController with session ownership check ---

  file "app/controllers/api/turns_controller.rb", <<~RUBY
    module Api
      class TurnsController < BaseController
        before_action :set_session

        def index
          render json: @session_record.turns.as_json(include: [:model, :preset])
        end

        def show
          turn = @session_record.turns.find(params[:id])
          render json: turn.as_json(include: [:model, :preset])
        end

        private

        def set_session
          @session_record = Session.find(params[:session_id])
          authorize!(@session_record, :show)
        end
      end
    end
  RUBY

  # --- Update ProvidersController with authorization ---

  file "app/controllers/api/providers_controller.rb", <<~RUBY
    module Api
      class ProvidersController < BaseController
        def index
          providers = scope(Provider).active.by_priority
          render json: providers.as_json(except: :api_key_ciphertext, include: :models)
        end

        def show
          provider = Provider.find(params[:id])
          authorize!(provider, :show)
          render json: provider.as_json(except: :api_key_ciphertext, include: { models: { include: :presets } })
        end

        def create
          provider = Provider.new(provider_params)
          authorize!(provider, :create)
          if provider.save
            render json: provider.as_json(except: :api_key_ciphertext), status: :created
          else
            render json: { errors: provider.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          provider = Provider.find(params[:id])
          authorize!(provider, :update)
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

  # --- Update ModelsController with authorization ---

  file "app/controllers/api/models_controller.rb", <<~RUBY
    module Api
      class ModelsController < BaseController
        def index
          models = if params[:provider_id]
            provider = Provider.find(params[:provider_id])
            authorize!(provider, :show)
            provider.models.active
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
          authorize!(provider, :update)
          model = provider.models.build(model_params)
          if model.save
            render json: model, status: :created
          else
            render json: { errors: model.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          model = Model.find(params[:id])
          authorize!(model.provider, :update)
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

  # --- Update PresetsController with authorization ---

  file "app/controllers/api/presets_controller.rb", <<~RUBY
    module Api
      class PresetsController < BaseController
        def index
          model = Model.find(params[:model_id])
          render json: scope(Preset).where(model_id: model.id)
        end

        def create
          model = Model.find(params[:model_id])
          preset = model.presets.build(preset_params)
          preset.user_id = current_user&.id
          authorize!(preset, :create)
          if preset.save
            render json: preset, status: :created
          else
            render json: { errors: preset.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          preset = Preset.find(params[:id])
          authorize!(preset, :update)
          if preset.update(preset_params)
            render json: preset
          else
            render json: { errors: preset.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          preset = Preset.find(params[:id])
          authorize!(preset, :destroy)
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

  # --- Add role helpers to User model ---

  inject_into_file "app/models/user.rb", after: "has_many :api_tokens, dependent: :destroy\n" do
    <<~RUBY

      def admin?
        role == "admin"
      end

      def member?
        role == "member"
      end
    RUBY
  end

  # --- Add user association to Session model ---

  inject_into_file "app/models/session.rb", after: "class Session < ApplicationRecord\n" do
    "  belongs_to :user, optional: true\n"
  end

  # --- Add user association to ApiToken model ---

  inject_into_file "app/models/api_token.rb", after: "class ApiToken < ApplicationRecord\n" do
    "  belongs_to :user, optional: true\n"
  end

  # --- Update account view to show role badge ---

  gsub_file "app/views/account/show.html.erb",
    '<span class="account-detail__value"><%= @user.name %></span>',
    '<span class="account-detail__value"><%= @user.name %> <% if @user.admin? %><span class="role-badge role-badge--admin">admin</span><% end %></span>'

  # --- Role badge CSS ---

  append_to_file "app/assets/stylesheets/auth.css", <<~CSS

    /* Role badges */
    .role-badge { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; text-transform: uppercase; margin-left: 8px; vertical-align: middle; }
    .role-badge--admin { background: #e8f5e9; color: #2e7d32; }
    .role-badge--member { background: #e3f2fd; color: #1565c0; }
  CSS

  # --- Admin seed ---

  append_to_file "db/seeds.rb", <<~RUBY

    # --- Admin user ---

    if User.where(role: "admin").empty?
      admin_email = ENV.fetch("ADMIN_EMAIL", "admin@example.com")
      admin_password = ENV.fetch("ADMIN_PASSWORD", "changeme123")

      admin = User.find_or_create_by!(email: admin_email) do |u|
        u.name = "Admin"
        u.password = admin_password
        u.password_confirmation = admin_password
        u.role = "admin"
        u.active = true
      end

      # Create admin subscription (unlimited)
      plan = Plan.find_by(slug: "individual", active: true)
      if plan && admin.active_subscription.nil?
        admin.subscriptions.create!(
          plan: plan,
          status: "active",
          current_period_start: Time.current,
          current_period_end: Time.current + 100.years,
          tokens_used: 0
        )
      end

      # Create admin API token
      token = admin.api_tokens.build(label: "admin-default")
      token.raw_token = SecureRandom.hex(32)
      token.token_digest = BCrypt::Password.create(token.raw_token)
      token.save!

      puts "Admin user created: \#{admin_email}"
      puts "Admin API token: \#{token.raw_token}"
    end
  RUBY
end
