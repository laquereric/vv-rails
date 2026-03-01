# modules/subscription.rb — Users, Plans, and Subscriptions
#
# Provides: User model (has_secure_password), Plan model, Subscription model
# with token tracking, seed data for Individual plan.
#
# Depends on: base, auth_token

gem "bcrypt", "~> 3.1"

after_bundle do
  # --- Migrations ---

  generate "migration", "CreateUsers email:string:uniq password_digest:string name:string active:boolean"
  generate "migration", "CreatePlans name:string slug:string:uniq token_limit:integer price_cents:integer billing_period:string active:boolean credit_limit:decimal"
  generate "migration", "CreateSubscriptions user:references plan:references status:string current_period_start:datetime current_period_end:datetime tokens_used:integer credits_used:decimal"

  # Set defaults on users migration
  users_migration = Dir.glob("db/migrate/*_create_users.rb").first
  if users_migration
    gsub_file users_migration, "t.boolean :active", "t.boolean :active, default: true"
  end

  # Set defaults on plans migration
  plans_migration = Dir.glob("db/migrate/*_create_plans.rb").first
  if plans_migration
    gsub_file plans_migration, "t.boolean :active", "t.boolean :active, default: true"
  end

  # Set defaults on subscriptions migration
  subs_migration = Dir.glob("db/migrate/*_create_subscriptions.rb").first
  if subs_migration
    gsub_file subs_migration, 't.string :status', 't.string :status, default: "active"'
    gsub_file subs_migration, 't.integer :tokens_used', 't.integer :tokens_used, default: 0'
    gsub_file subs_migration, 't.decimal :credits_used', 't.decimal :credits_used, precision: 10, scale: 4, default: 0'
  end

  # Add user_id to api_tokens (ties tokens to users)
  generate "migration", "AddUserToApiTokens user:references"

  # --- User model ---

  file "app/models/user.rb", <<~RUBY
    class User < ApplicationRecord
      has_secure_password

      has_many :subscriptions, dependent: :destroy
      has_many :api_tokens, dependent: :destroy

      validates :email, presence: true, uniqueness: { case_sensitive: false },
                        format: { with: URI::MailTo::EMAIL_REGEXP }
      validates :name, presence: true

      scope :active, -> { where(active: true) }

      def active_subscription
        subscriptions.where(status: "active")
                     .where("current_period_end > ?", Time.current)
                     .order(created_at: :desc)
                     .first
      end

      def token_budget_remaining
        sub = active_subscription
        return 0 unless sub
        [sub.plan.token_limit - sub.tokens_used, 0].max
      end

      def credit_budget_remaining
        sub = active_subscription
        return nil unless sub&.plan&.credit_based?
        sub.credits_remaining
      end
    end
  RUBY

  # --- Plan model ---

  file "app/models/plan.rb", <<~RUBY
    class Plan < ApplicationRecord
      has_many :subscriptions, dependent: :restrict_with_error

      validates :name, presence: true
      validates :slug, presence: true, uniqueness: true
      validates :token_limit, presence: true, numericality: { greater_than: 0 }
      validates :price_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }

      scope :active, -> { where(active: true) }

      def price_dollars
        price_cents / 100.0
      end

      def credit_based?
        credit_limit.present? && credit_limit > 0
      end
    end
  RUBY

  # --- Subscription model ---

  file "app/models/subscription.rb", <<~RUBY
    class Subscription < ApplicationRecord
      belongs_to :user
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

  # --- Seed data ---

  append_to_file "db/seeds.rb", <<~RUBY

    # --- Subscription Plans ---

    Plan.find_or_create_by!(slug: "individual") do |p|
      p.name = "Individual"
      p.token_limit = 1_000_000
      p.price_cents = 300
      p.billing_period = "monthly"
      p.active = true
    end

    Plan.find_or_create_by!(slug: "power_user") do |p|
      p.name = "Power User"
      p.token_limit = 10_000_000
      p.price_cents = 2500
      p.billing_period = "monthly"
      p.credit_limit = 25.0
      p.active = true
    end

    Plan.find_or_create_by!(slug: "group") do |p|
      p.name = "Group"
      p.token_limit = 100_000_000
      p.price_cents = 10000
      p.billing_period = "monthly"
      p.active = false  # Not yet available
    end
  RUBY
end
