# modules/multi_tenant.rb — Group / Multi-Tenancy
#
# Provides: Tenant model, TenantMembership model, TenantSubscription model,
# Current (ActiveSupport::CurrentAttributes), TenantScopedModel concern,
# TenantContext concern, TenantMeteringService, updated policies with
# tenant scoping, Rack::Attack rate limiting, vv-memory tenant integration,
# registration flow update, tenant seeds.
#
# Depends on: base, auth_token, subscription, metering, auth_user,
#             authorization, api_rest, api_relay, power_user


@vv_applied_modules ||= []; @vv_applied_modules << "multi_tenant"

gem "rack-attack", "~> 6.7"

after_bundle do
  # ─── Migrations ───────────────────────────────────────────────────────

  # 1. Tenants table
  generate "migration", "CreateTenants name:string slug:string:uniq tier:string settings:json active:boolean"

  tenants_migration = Dir.glob("db/migrate/*_create_tenants.rb").first
  if tenants_migration
    gsub_file tenants_migration, 't.string :tier', 't.string :tier, default: "individual"'
    gsub_file tenants_migration, 't.json :settings', 't.json :settings, default: {}'
    gsub_file tenants_migration, 't.boolean :active', 't.boolean :active, default: true'
  end

  # 2. Tenant memberships table
  generate "migration", "CreateTenantMemberships user:references tenant:references role:string"

  memberships_migration = Dir.glob("db/migrate/*_create_tenant_memberships.rb").first
  if memberships_migration
    gsub_file memberships_migration, 't.string :role', 't.string :role, default: "member"'
    # Add unique index on [user_id, tenant_id] inside the create_table block
    gsub_file memberships_migration,
      "t.timestamps",
      "t.timestamps\n\n      t.index [:user_id, :tenant_id], unique: true"
  end

  # 3. Tenant subscriptions table (shared pool)
  generate "migration", "CreateTenantSubscriptions tenant:references plan:references status:string current_period_start:datetime current_period_end:datetime tokens_used:integer credits_used:decimal"

  tenant_subs_migration = Dir.glob("db/migrate/*_create_tenant_subscriptions.rb").first
  if tenant_subs_migration
    gsub_file tenant_subs_migration, 't.string :status', 't.string :status, default: "active"'
    gsub_file tenant_subs_migration, 't.integer :tokens_used', 't.integer :tokens_used, default: 0'
    gsub_file tenant_subs_migration, 't.decimal :credits_used', 't.decimal :credits_used, precision: 10, scale: 4, default: 0'
  end

  # 4. Add tenant_id to sessions
  generate "migration", "AddTenantToSessions tenant:references"

  sessions_tenant_migration = Dir.glob("db/migrate/*_add_tenant_to_sessions.rb").last
  if sessions_tenant_migration
    gsub_file sessions_tenant_migration, "null: false", "null: true"
  end

  # 5. Add tenant_id to api_tokens
  generate "migration", "AddTenantToApiTokens tenant:references"

  tokens_tenant_migration = Dir.glob("db/migrate/*_add_tenant_to_api_tokens.rb").last
  if tokens_tenant_migration
    gsub_file tokens_tenant_migration, "null: false", "null: true"
  end

  # 6. Add tenant_id to agents
  generate "migration", "AddTenantToAgents tenant:references"

  agents_tenant_migration = Dir.glob("db/migrate/*_add_tenant_to_agents.rb").last
  if agents_tenant_migration
    gsub_file agents_tenant_migration, "null: false", "null: true"
  end

  # 7-9. Add tenant_id to vv-memory tables (app-level, no FK constraint)
  generate "migration", "AddTenantIdToVvMemoryFacts tenant_id:integer:index"
  generate "migration", "AddTenantIdToVvMemoryOpinions tenant_id:integer:index"
  generate "migration", "AddTenantIdToVvMemoryObservations tenant_id:integer:index"

  # ─── Current (ActiveSupport::CurrentAttributes) ───────────────────────

  file "app/models/current.rb", <<~RUBY
    class Current < ActiveSupport::CurrentAttributes
      attribute :user, :tenant, :subscription, :tenant_subscription
    end
  RUBY

  # ─── Tenant model ─────────────────────────────────────────────────────

  file "app/models/tenant.rb", <<~RUBY
    class Tenant < ApplicationRecord
      TIERS = %w[individual power_user group].freeze

      TIER_DEFAULTS = {
        "individual"  => { rate_limit_relay_per_min: 30,  max_concurrent_sessions: 5 },
        "power_user"  => { rate_limit_relay_per_min: 120, max_concurrent_sessions: 25 },
        "group"       => { rate_limit_relay_per_min: 600, max_concurrent_sessions: 100 }
      }.freeze

      has_many :tenant_memberships, dependent: :destroy
      has_many :users, through: :tenant_memberships
      has_many :tenant_subscriptions, dependent: :destroy
      has_many :sessions, dependent: :nullify
      has_many :api_tokens, dependent: :nullify
      has_many :agents, dependent: :nullify

      validates :name, presence: true
      validates :slug, presence: true, uniqueness: true,
                       format: { with: /\\A[a-z0-9][a-z0-9_-]*\\z/, message: "must be lowercase alphanumeric with dashes/underscores" }
      validates :tier, inclusion: { in: TIERS }

      scope :active, -> { where(active: true) }

      def active_tenant_subscription
        tenant_subscriptions.where(status: "active")
                            .where("current_period_end > ?", Time.current)
                            .order(created_at: :desc)
                            .first
      end

      def rate_limit_relay_per_min
        settings&.dig("rate_limit_relay_per_min") || TIER_DEFAULTS.dig(tier, :rate_limit_relay_per_min) || 30
      end

      def max_concurrent_sessions
        settings&.dig("max_concurrent_sessions") || TIER_DEFAULTS.dig(tier, :max_concurrent_sessions) || 5
      end
    end
  RUBY

  # ─── TenantMembership model ───────────────────────────────────────────

  file "app/models/tenant_membership.rb", <<~RUBY
    class TenantMembership < ApplicationRecord
      ROLES = %w[admin member].freeze

      belongs_to :user
      belongs_to :tenant

      validates :role, inclusion: { in: ROLES }
      validates :user_id, uniqueness: { scope: :tenant_id, message: "is already a member of this tenant" }

      scope :admins, -> { where(role: "admin") }
      scope :members, -> { where(role: "member") }

      def admin?
        role == "admin"
      end
    end
  RUBY

  # ─── TenantSubscription model (shared pool) ───────────────────────────

  file "app/models/tenant_subscription.rb", <<~RUBY
    class TenantSubscription < ApplicationRecord
      belongs_to :tenant
      belongs_to :plan

      validates :status, inclusion: { in: %w[active canceled expired] }

      scope :active, -> { where(status: "active") }
      scope :current, -> { where("current_period_end > ?", Time.current) }

      def active?
        status == "active" && current_period_end > Time.current
      end

      def tokens_remaining
        [plan.token_limit - tokens_used, 0].max
      end

      def credits_remaining
        return nil unless plan.credit_based?
        [plan.credit_limit - credits_used, 0].max
      end

      def quota_exceeded?
        if plan.credit_based?
          credits_used >= plan.credit_limit
        else
          tokens_used >= plan.token_limit
        end
      end

      def record_usage!(input_tokens, output_tokens, model: nil)
        increment!(:tokens_used, input_tokens.to_i + output_tokens.to_i)
        if plan.credit_based? && model&.has_cost?
          cost = model.cost_for(input_tokens, output_tokens)
          increment!(:credits_used, cost) if cost > 0
        end
      end

      def reset_period!
        next_start = current_period_end
        next_end = case plan.billing_period
                   when "monthly" then next_start + 1.month
                   when "yearly" then next_start + 1.year
                   else next_start + 1.month
                   end
        update!(
          tokens_used: 0,
          credits_used: 0,
          current_period_start: next_start,
          current_period_end: next_end
        )
      end

      def usage_percentage
        if plan.credit_based?
          return 0 if plan.credit_limit.zero?
          (credits_used.to_f / plan.credit_limit * 100).round(1)
        else
          return 0 if plan.token_limit.zero?
          (tokens_used.to_f / plan.token_limit * 100).round(1)
        end
      end
    end
  RUBY

  # ─── TenantScopedModel concern ────────────────────────────────────────

  file "app/models/concerns/tenant_scoped_model.rb", <<~RUBY
    module TenantScopedModel
      extend ActiveSupport::Concern

      included do
        belongs_to :tenant, optional: true

        before_create :set_tenant_from_current

        default_scope do
          tenant_id = Thread.current[:current_tenant_id]
          if tenant_id
            where(tenant_id: [nil, tenant_id])
          else
            all  # Platform admin or non-tenanted context
          end
        end
      end

      private

      def set_tenant_from_current
        self.tenant_id ||= Current.tenant&.id
      end
    end
  RUBY

  # ─── Inject TenantScopedModel into Session ────────────────────────────

  inject_into_file "app/models/session.rb", after: "class Session < ApplicationRecord\n" do
    "  include TenantScopedModel\n"
  end

  # ─── Inject TenantScopedModel into Agent ──────────────────────────────

  inject_into_file "app/models/agent.rb", after: "class Agent < ApplicationRecord\n" do
    "  include TenantScopedModel\n"
  end

  # ─── Inject tenant associations into ApiToken ─────────────────────────

  inject_into_file "app/models/api_token.rb", after: "belongs_to :user, optional: true\n" do
    "  belongs_to :tenant, optional: true\n"
  end

  # ─── Inject tenant associations + helpers into User ───────────────────

  inject_into_file "app/models/user.rb", after: "has_many :agents, dependent: :destroy\n" do
    <<~RUBY
      has_many :tenant_memberships, dependent: :destroy
      has_many :tenants, through: :tenant_memberships

      def primary_tenant
        tenants.first
      end

      def accessible_tenant_ids
        tenant_memberships.pluck(:tenant_id)
      end

      def tenant_admin?(tenant)
        tenant_memberships.exists?(tenant_id: tenant.id, role: "admin")
      end

      def member_of?(tenant)
        tenant_memberships.exists?(tenant_id: tenant.id)
      end
    RUBY
  end

  # ─── TenantMeteringService ────────────────────────────────────────────

  file "app/services/tenant_metering_service.rb", <<~RUBY
    class TenantMeteringService
      class TenantQuotaExceededError < StandardError; end

      # Check quota at both tenant and user levels
      def self.check_quota!(tenant_subscription:, user_subscription:)
        # Check tenant shared pool first
        if tenant_subscription&.quota_exceeded?
          raise TenantQuotaExceededError,
            "Tenant quota exceeded. " \\
            "Used \#{tenant_subscription.tokens_used.to_fs(:delimited)} " \\
            "of \#{tenant_subscription.plan.token_limit.to_fs(:delimited)} shared tokens. " \\
            "Resets at \#{tenant_subscription.current_period_end.strftime('%Y-%m-%d')}."
        end

        # Then check individual user quota
        MeteringService.check_quota!(user_subscription)
      end

      # Record usage at both levels
      def self.record_usage!(tenant_subscription:, user_subscription:, input_tokens:, output_tokens:, model: nil)
        tenant_subscription&.record_usage!(input_tokens, output_tokens, model: model)
        MeteringService.record_usage!(user_subscription, input_tokens: input_tokens, output_tokens: output_tokens, model: model)
      end

      # Maybe reset billing periods at both levels
      def self.maybe_reset_periods!(tenant_subscription:, user_subscription:)
        if tenant_subscription && tenant_subscription.current_period_end <= Time.current
          tenant_subscription.reset_period!
        end
        MeteringService.maybe_reset_period!(user_subscription)
      end

      # Usage summary for both levels
      def self.usage_summary(tenant_subscription:, user_subscription:)
        {
          tenant: tenant_subscription ? MeteringService.usage_summary(tenant_subscription) : nil,
          individual: MeteringService.usage_summary(user_subscription)
        }
      end
    end
  RUBY

  # ─── TenantContext concern ────────────────────────────────────────────

  file "app/controllers/concerns/tenant_context.rb", <<~RUBY
    module TenantContext
      extend ActiveSupport::Concern

      included do
        before_action :set_tenant_context
        after_action :clear_tenant_context
      end

      private

      def set_tenant_context
        Current.user = current_user
        return unless Current.user

        # Resolve tenant from API token or user's primary tenant
        token_str = request.headers["Authorization"]&.delete_prefix("Bearer ")
        api_token = token_str.present? ? ApiToken.authenticate(token_str) : nil

        Current.tenant = if api_token&.tenant_id
          api_token.tenant
        else
          Current.user.primary_tenant
        end

        Current.subscription = Current.user.active_subscription
        Current.tenant_subscription = Current.tenant&.active_tenant_subscription

        # Set thread-local for default_scope (platform admin operates unscoped)
        Thread.current[:current_tenant_id] = unless Current.user.admin?
          Current.tenant&.id
        end
      end

      def clear_tenant_context
        Thread.current[:current_tenant_id] = nil
        Current.reset
      end
    end
  RUBY

  # ─── Update Api::BaseController to include TenantContext ──────────────

  file "app/controllers/api/base_controller.rb", <<~RUBY
    module Api
      class BaseController < ActionController::API
        include Authorization
        include TenantContext

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

  # ─── Update Metered concern for dual-level metering ───────────────────

  file "app/controllers/concerns/metered.rb", <<~RUBY
    module Metered
      extend ActiveSupport::Concern

      included do
        before_action :check_quota, only: [:create]
      end

      private

      def current_subscription
        return @current_subscription if defined?(@current_subscription)
        @current_subscription = current_user&.active_subscription
      end

      def current_tenant_subscription
        return @current_tenant_subscription if defined?(@current_tenant_subscription)
        @current_tenant_subscription = Current.tenant&.active_tenant_subscription
      end

      def current_user
        return @current_user if defined?(@current_user)
        token_str = request.headers["Authorization"]&.delete_prefix("Bearer ")
        api_token = token_str.present? ? ApiToken.authenticate(token_str) : nil
        @current_user = api_token&.user
      end

      def check_quota
        return unless current_subscription  # No subscription = no enforcement

        if current_tenant_subscription
          # Dual-level: check both tenant pool and individual quota
          TenantMeteringService.maybe_reset_periods!(
            tenant_subscription: current_tenant_subscription,
            user_subscription: current_subscription
          )
          TenantMeteringService.check_quota!(
            tenant_subscription: current_tenant_subscription,
            user_subscription: current_subscription
          )
        else
          # Individual mode (no tenant)
          MeteringService.maybe_reset_period!(current_subscription)
          MeteringService.check_quota!(current_subscription)
        end
      rescue TenantMeteringService::TenantQuotaExceededError => e
        render json: { error: e.message, quota_exceeded: true, level: "tenant" }, status: :too_many_requests
      rescue MeteringService::QuotaExceededError => e
        render json: { error: e.message, quota_exceeded: true, level: "individual" }, status: :too_many_requests
      end

      def record_token_usage(input_tokens, output_tokens, model: nil)
        if current_tenant_subscription
          TenantMeteringService.record_usage!(
            tenant_subscription: current_tenant_subscription,
            user_subscription: current_subscription,
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            model: model
          )
        else
          MeteringService.record_usage!(
            current_subscription,
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            model: model
          )
        end
      end
    end
  RUBY

  # ─── Update UsageController with tenant-aware usage summary ───────────

  file "app/controllers/api/usage_controller.rb", <<~RUBY
    module Api
      class UsageController < BaseController
        def show
          user = current_user
          unless user
            render json: { error: "No user associated with this token" }, status: :not_found
            return
          end

          subscription = user.active_subscription
          unless subscription
            render json: { error: "No active subscription" }, status: :not_found
            return
          end

          MeteringService.maybe_reset_period!(subscription)

          tenant_sub = Current.tenant&.active_tenant_subscription
          if tenant_sub
            TenantMeteringService.maybe_reset_periods!(
              tenant_subscription: tenant_sub,
              user_subscription: subscription
            )
            render json: TenantMeteringService.usage_summary(
              tenant_subscription: tenant_sub,
              user_subscription: subscription
            )
          else
            render json: MeteringService.usage_summary(subscription)
          end
        end
      end
    end
  RUBY

  # ─── Updated Policies ────────────────────────────────────────────────

  # ApplicationPolicy — add tenant helpers
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

      def same_tenant?
        return true if admin?
        return false unless user && record.respond_to?(:tenant_id) && record.tenant_id
        user.accessible_tenant_ids.include?(record.tenant_id)
      end

      def tenant_admin?
        return true if admin?
        return false unless user && Current.tenant
        user.tenant_admin?(Current.tenant)
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

  # SessionPolicy — admin→all, tenant_admin→tenant sessions, member→own
  file "app/policies/session_policy.rb", <<~RUBY
    class SessionPolicy < ApplicationPolicy
      def index?;   true end
      def show?;    admin? || owner? || (same_tenant? && tenant_admin?) end
      def create?;  true end
      def update?;  admin? || owner? end
      def destroy?; admin? || owner? end

      class Scope < ApplicationPolicy::Scope
        def resolve
          if user&.role == "admin"
            model.all
          elsif user && Current.tenant && user.tenant_admin?(Current.tenant)
            # Tenant admins see all tenant sessions
            model.unscoped.where(tenant_id: Current.tenant.id)
          else
            model.where(user_id: user&.id)
          end
        end
      end
    end
  RUBY

  # ProviderPolicy — unchanged (providers are global)
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

  # PresetPolicy — tenant_admin can manage tenant presets
  file "app/policies/preset_policy.rb", <<~RUBY
    class PresetPolicy < ApplicationPolicy
      def index?;   true end
      def show?;    true end
      def create?;  true end
      def update?;  admin? || owner? || tenant_admin? end
      def destroy?; admin? || owner? || tenant_admin? end

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

  # AgentPolicy — public agents visible within same tenant only
  file "app/policies/agent_policy.rb", <<~RUBY
    class AgentPolicy < ApplicationPolicy
      def index?;   true end
      def show?;    admin? || owner? || (record.public? && same_tenant?) end
      def create?;  true end
      def update?;  admin? || owner? end
      def destroy?; admin? || owner? end
      def invoke?;  admin? || owner? || (record.public? && same_tenant?) end

      class Scope < ApplicationPolicy::Scope
        def resolve
          if user&.role == "admin"
            model.all
          else
            own = model.where(user_id: user&.id)
            if Current.tenant
              own.or(model.where(public: true, active: true, tenant_id: [nil, Current.tenant.id]))
            else
              own.or(model.where(public: true, active: true, tenant_id: nil))
            end
          end
        end
      end
    end
  RUBY

  # ─── TenantsController ───────────────────────────────────────────────

  file "app/controllers/v1/tenants_controller.rb", <<~RUBY
    module V1
      class TenantsController < Api::BaseController
        before_action :set_tenant, only: [:show, :update, :members]

        def index
          tenants = if current_user&.admin?
            Tenant.all
          else
            current_user&.tenants || Tenant.none
          end
          render json: tenants.as_json(methods: [:rate_limit_relay_per_min, :max_concurrent_sessions])
        end

        def show
          authorize!(@tenant, :show)
          render json: @tenant.as_json(
            include: { tenant_memberships: { include: :user } },
            methods: [:rate_limit_relay_per_min, :max_concurrent_sessions]
          )
        end

        def update
          authorize!(@tenant, :update)
          if @tenant.update(tenant_params)
            render json: @tenant
          else
            render json: { errors: @tenant.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def members
          authorize!(@tenant, :show)
          memberships = @tenant.tenant_memberships.includes(:user)
          render json: memberships.as_json(include: :user)
        end

        private

        def set_tenant
          @tenant = Tenant.find(params[:id])
        end

        def tenant_params
          params.require(:tenant).permit(:name, settings: {})
        end
      end
    end
  RUBY

  # TenantPolicy
  file "app/policies/tenant_policy.rb", <<~RUBY
    class TenantPolicy < ApplicationPolicy
      def index?;   true end
      def show?;    admin? || same_tenant? end
      def create?;  admin? end
      def update?;  admin? || tenant_admin? end
      def destroy?; admin? end

      class Scope < ApplicationPolicy::Scope
        def resolve
          if user&.role == "admin"
            model.all
          else
            model.where(id: user&.accessible_tenant_ids)
          end
        end
      end
    end
  RUBY

  # ─── Tenant routes ───────────────────────────────────────────────────

  route <<~RUBY
    namespace :v1 do
      resources :tenants, only: [:index, :show, :update] do
        member do
          get :members
        end
      end
    end
  RUBY

  # ─── Rack::Attack rate limiting ──────────────────────────────────────

  initializer "rack_attack.rb", <<~'RUBY'
    class Rack::Attack
      # --- Relay throttle per tenant ---
      throttle("relay/tenant", limit: proc { |req|
        token_str = req.env["HTTP_AUTHORIZATION"]&.delete_prefix("Bearer ")
        if token_str
          api_token = ApiToken.authenticate(token_str)
          tenant = api_token&.tenant || api_token&.user&.primary_tenant
          tenant&.rate_limit_relay_per_min || 30
        else
          30
        end
      }, period: 1.minute) do |req|
        if req.path == "/api/relay" && req.post?
          token_str = req.env["HTTP_AUTHORIZATION"]&.delete_prefix("Bearer ")
          if token_str
            api_token = ApiToken.authenticate(token_str)
            tenant = api_token&.tenant || api_token&.user&.primary_tenant
            "relay:#{tenant&.id || 'anon'}"
          end
        end
      end

      # --- API throttle per token ---
      throttle("api/token", limit: 300, period: 1.minute) do |req|
        if req.path.start_with?("/api/", "/v1/")
          req.env["HTTP_AUTHORIZATION"]&.delete_prefix("Bearer ")
        end
      end

      # --- Login throttle per IP ---
      throttle("login/ip", limit: 10, period: 1.minute) do |req|
        req.ip if req.path == "/login" && req.post?
      end

      # --- Register throttle per IP ---
      throttle("register/ip", limit: 5, period: 5.minutes) do |req|
        req.ip if req.path == "/register" && req.post?
      end

      # --- Custom 429 JSON response ---
      self.throttled_responder = lambda do |req|
        match_data = req.env["rack.attack.match_data"]
        now = match_data[:epoch_time]
        retry_after = match_data[:period] - (now % match_data[:period])

        [
          429,
          {
            "Content-Type" => "application/json",
            "Retry-After" => retry_after.to_s
          },
          [{ error: "Rate limit exceeded. Retry after #{retry_after} seconds.", retry_after: retry_after }.to_json]
        ]
      end
    end
  RUBY

  # Enable Rack::Attack middleware
  environment <<~RUBY
    config.middleware.use Rack::Attack
  RUBY

  # ─── vv-memory tenant integration ────────────────────────────────────

  initializer "vv_memory_tenant.rb", <<~'RUBY'
    Rails.application.config.after_initialize do
      next unless defined?(Vv::Memory)

      # Guard: only patch if tables exist (skip during migrations)
      begin
        has_tenant_col = Vv::Memory::Fact.table_exists? &&
                         Vv::Memory::Fact.column_names.include?("tenant_id")
      rescue ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError
        next
      end
      next unless has_tenant_col

      # Add tenant scoping to memory models
      [Vv::Memory::Fact, Vv::Memory::Opinion, Vv::Memory::Observation].each do |klass|
        klass.class_eval do
          scope :for_tenant, ->(tenant_id) { where(tenant_id: [nil, tenant_id]) }
        end
      end

      # Patch Fact.retain! to set tenant_id from Current
      Vv::Memory::Fact.class_eval do
        class << self
          alias_method :original_retain!, :retain!

          def retain!(**kwargs)
            result = original_retain!(**kwargs)
            if result.respond_to?(:tenant_id=) && result.tenant_id.nil? && Current.tenant
              result.update_column(:tenant_id, Current.tenant.id)
            end
            result
          end
        end
      end

      # Patch Observation.track! to set tenant_id from Current
      Vv::Memory::Observation.class_eval do
        class << self
          alias_method :original_track!, :track!

          def track!(**kwargs)
            result = original_track!(**kwargs)
            if result.respond_to?(:tenant_id=) && result.tenant_id.nil? && Current.tenant
              result.update_column(:tenant_id, Current.tenant.id)
            end
            result
          end
        end
      end

      # Patch Recall.call to scope queries by tenant
      Vv::Memory::Recall.class_eval do
        class << self
          alias_method :original_call, :call

          def call(session, context: nil)
            result = original_call(session, context: context)

            # Filter results by tenant if tenant context is set
            if Current.tenant
              tenant_id = Current.tenant.id
              result[:facts] = result[:facts].select { |f| f.tenant_id.nil? || f.tenant_id == tenant_id } if result[:facts]
              result[:opinions] = result[:opinions].select { |o| o.tenant_id.nil? || o.tenant_id == tenant_id } if result[:opinions]
              result[:observations] = result[:observations].select { |o| o.tenant_id.nil? || o.tenant_id == tenant_id } if result[:observations]
            end

            result
          end
        end
      end
    end
  RUBY

  # ─── Update RegistrationsController for tenant auto-creation ──────────

  file "app/controllers/registrations_controller.rb", <<~RUBY
    class RegistrationsController < ApplicationController
      skip_before_action :require_login, only: [:new, :create], raise: false

      def new
        redirect_to root_path if current_user
        @user = User.new
      end

      def create
        @user = User.new(user_params)
        if @user.save
          # 1. Create Individual subscription
          plan = Plan.find_by(slug: "individual", active: true)
          if plan
            @user.subscriptions.create!(
              plan: plan,
              status: "active",
              current_period_start: Time.current,
              current_period_end: Time.current + 1.month,
              tokens_used: 0
            )
          end

          # 2. Auto-create personal tenant
          tenant = Tenant.create!(
            name: @user.name,
            slug: "user-\#{@user.id}",
            tier: "individual"
          )

          # 3. Create membership (user as admin of own tenant)
          TenantMembership.create!(
            user: @user,
            tenant: tenant,
            role: "admin"
          )

          # 4. Create tenant subscription
          if plan
            TenantSubscription.create!(
              tenant: tenant,
              plan: plan,
              status: "active",
              current_period_start: Time.current,
              current_period_end: Time.current + 1.month,
              tokens_used: 0
            )
          end

          session[:user_id] = @user.id
          redirect_to root_path, notice: "Account created"
        else
          render :new, status: :unprocessable_entity
        end
      end

      private

      def user_params
        params.require(:user).permit(:name, :email, :password, :password_confirmation)
      end
    end
  RUBY

  # ─── Seeds ────────────────────────────────────────────────────────────

  append_to_file "db/seeds.rb", <<~RUBY

    # --- Multi-Tenancy ---

    # Activate Group plan
    group_plan = Plan.find_by(slug: "group")
    if group_plan && !group_plan.active?
      group_plan.update!(active: true, credit_limit: 100.0)
      puts "Group plan activated"
    end

    # Create default tenant
    default_tenant = Tenant.find_or_create_by!(slug: "default") do |t|
      t.name = "Default"
      t.tier = "individual"
      t.active = true
    end

    # Create tenant subscription for default tenant
    individual_plan = Plan.find_by(slug: "individual", active: true)
    if individual_plan && default_tenant.active_tenant_subscription.nil?
      TenantSubscription.create!(
        tenant: default_tenant,
        plan: individual_plan,
        status: "active",
        current_period_start: Time.current,
        current_period_end: Time.current + 100.years,
        tokens_used: 0
      )
    end

    # Assign admin user to default tenant
    admin = User.find_by(role: "admin")
    if admin && !admin.member_of?(default_tenant)
      TenantMembership.create!(
        user: admin,
        tenant: default_tenant,
        role: "admin"
      )
      puts "Admin assigned to default tenant"
    end

    # Assign admin's API tokens to default tenant
    if admin
      admin.api_tokens.where(tenant_id: nil).update_all(tenant_id: default_tenant.id)
      puts "Admin API tokens assigned to default tenant"
    end
  RUBY
end
