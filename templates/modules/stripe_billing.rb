# modules/stripe_billing.rb — Stripe Checkout, Webhooks, Customer Portal
#
# Provides: StripeService, WebhooksController (POST /webhooks/stripe),
# BillingController (GET /billing, /billing/checkout), Stripe initializer,
# migrations for stripe_customer_id, stripe_subscription_id, stripe_price_id,
# stripe_product_id. Patches RegistrationsController to create Stripe Customer
# and redirect to Checkout. Patches MeteringService to skip period reset for
# Stripe-managed subscriptions. Patches account view with billing links.
#
# Graceful degradation: if STRIPE_SECRET_KEY is blank, falls back to direct
# subscription creation (current behavior). Works without Stripe in dev.
#
# Depends on: base, subscription, metering, auth_user

gem "stripe", ">= 10.0"

after_bundle do
  # ─── Migrations ───────────────────────────────────────────────────────

  generate "migration", "AddStripeCustomerIdToUsers stripe_customer_id:string"

  users_stripe_migration = Dir.glob("db/migrate/*_add_stripe_customer_id_to_users.rb").first
  if users_stripe_migration
    gsub_file users_stripe_migration,
      "t.string :stripe_customer_id",
      "t.string :stripe_customer_id\n      t.index :stripe_customer_id, unique: true"
  end

  generate "migration", "AddStripeFieldsToSubscriptions stripe_subscription_id:string stripe_price_id:string"

  subs_stripe_migration = Dir.glob("db/migrate/*_add_stripe_fields_to_subscriptions.rb").first
  if subs_stripe_migration
    gsub_file subs_stripe_migration,
      "t.string :stripe_subscription_id",
      "t.string :stripe_subscription_id\n      t.index :stripe_subscription_id, unique: true"
  end

  generate "migration", "AddStripeFieldsToPlans stripe_product_id:string stripe_price_id:string"

  # ─── Initializer ────────────────────────────────────────────────────

  initializer "stripe.rb", <<~'RUBY'
    Stripe.api_key = ENV["STRIPE_SECRET_KEY"] if ENV["STRIPE_SECRET_KEY"].present?

    Rails.application.config.stripe = ActiveSupport::OrderedOptions.new
    Rails.application.config.stripe.publishable_key = ENV["STRIPE_PUBLISHABLE_KEY"]
    Rails.application.config.stripe.webhook_secret = ENV["STRIPE_WEBHOOK_SECRET"]
  RUBY

  # ─── StripeService ──────────────────────────────────────────────────

  file "app/services/stripe_service.rb", <<~'RUBY'
    class StripeService
      class << self
        def stripe_configured?
          ENV["STRIPE_SECRET_KEY"].present?
        end

        # Create a Stripe Customer and save ID to user
        def create_customer(user)
          return unless stripe_configured?

          customer = Stripe::Customer.create(
            email: user.email,
            name: user.name,
            metadata: { user_id: user.id }
          )
          user.update!(stripe_customer_id: customer.id)
          customer
        end

        # Create a Stripe Checkout Session for subscription
        def create_checkout_session(user:, plan:, success_url:, cancel_url:)
          return unless stripe_configured? && plan.stripe_price_id.present?

          # Ensure user has a Stripe Customer
          create_customer(user) if user.stripe_customer_id.blank?

          Stripe::Checkout::Session.create(
            customer: user.stripe_customer_id,
            mode: "subscription",
            line_items: [{
              price: plan.stripe_price_id,
              quantity: 1
            }],
            success_url: success_url,
            cancel_url: cancel_url,
            metadata: {
              user_id: user.id,
              plan_id: plan.id
            }
          )
        end

        # Create a Stripe Customer Portal session
        def create_billing_portal_session(user:, return_url:)
          return unless stripe_configured? && user.stripe_customer_id.present?

          Stripe::BillingPortal::Session.create(
            customer: user.stripe_customer_id,
            return_url: return_url
          )
        end

        # Sync a local Subscription from Stripe webhook data
        def sync_subscription_from_stripe(stripe_sub)
          user = User.find_by(stripe_customer_id: stripe_sub.customer)
          return unless user

          plan = Plan.find_by(stripe_price_id: stripe_sub.items.data.first&.price&.id)
          plan ||= Plan.find_by(slug: "individual", active: true)
          return unless plan

          subscription = Subscription.find_or_initialize_by(
            stripe_subscription_id: stripe_sub.id
          )

          subscription.assign_attributes(
            user: user,
            plan: plan,
            status: map_stripe_status(stripe_sub.status),
            stripe_price_id: stripe_sub.items.data.first&.price&.id,
            current_period_start: Time.at(stripe_sub.current_period_start),
            current_period_end: Time.at(stripe_sub.current_period_end)
          )

          # Reset counters for new subscriptions
          if subscription.new_record?
            subscription.tokens_used = 0
            subscription.credits_used = 0
          end

          subscription.save!

          # Sync tenant subscription if multi-tenant is active
          sync_tenant_subscription(user, subscription) if defined?(TenantSubscription)

          subscription
        end

        # Handle invoice.payment_succeeded — reset period counters
        def handle_invoice_paid(invoice)
          return unless invoice.subscription.present?

          subscription = Subscription.find_by(
            stripe_subscription_id: invoice.subscription
          )
          return unless subscription

          # Only reset on new billing period (not first invoice)
          if invoice.billing_reason == "subscription_cycle"
            subscription.update!(
              tokens_used: 0,
              credits_used: 0,
              current_period_start: Time.at(invoice.period_start),
              current_period_end: Time.at(invoice.period_end)
            )

            # Reset tenant subscription too
            if defined?(TenantSubscription)
              tenant_sub = TenantSubscription.find_by(
                stripe_subscription_id: subscription.stripe_subscription_id
              )
              tenant_sub&.update!(tokens_used: 0, credits_used: 0)
            end

            Rails.logger.info("[Stripe] Period reset for subscription #{subscription.id}")
          end
        end

        # Handle customer.subscription.deleted — cancel subscription
        def handle_subscription_deleted(stripe_sub)
          subscription = Subscription.find_by(
            stripe_subscription_id: stripe_sub.id
          )
          return unless subscription

          subscription.update!(status: "canceled")

          if defined?(TenantSubscription)
            tenant_sub = TenantSubscription.find_by(
              stripe_subscription_id: stripe_sub.id
            )
            tenant_sub&.update!(status: "canceled")
          end

          Rails.logger.info("[Stripe] Subscription #{subscription.id} canceled")
        end

        private

        def map_stripe_status(stripe_status)
          case stripe_status
          when "active", "trialing" then "active"
          when "canceled", "unpaid" then "canceled"
          when "past_due", "incomplete" then "active" # still usable
          else "active"
          end
        end

        def sync_tenant_subscription(user, subscription)
          tenant = user.respond_to?(:primary_tenant) ? user.primary_tenant : nil
          return unless tenant

          tenant_sub = TenantSubscription.find_or_initialize_by(
            stripe_subscription_id: subscription.stripe_subscription_id
          )

          tenant_sub.assign_attributes(
            tenant: tenant,
            plan: subscription.plan,
            status: subscription.status,
            current_period_start: subscription.current_period_start,
            current_period_end: subscription.current_period_end
          )

          if tenant_sub.new_record?
            tenant_sub.tokens_used = 0
            tenant_sub.credits_used = 0
          end

          tenant_sub.save!
        end
      end
    end
  RUBY

  # ─── WebhooksController ────────────────────────────────────────────

  file "app/controllers/webhooks_controller.rb", <<~'RUBY'
    class WebhooksController < ApplicationController
      skip_before_action :verify_authenticity_token, raise: false
      skip_before_action :require_login, raise: false

      def stripe
        payload = request.body.read
        sig_header = request.env["HTTP_STRIPE_SIGNATURE"]
        webhook_secret = Rails.application.config.stripe.webhook_secret

        begin
          event = if webhook_secret.present?
            Stripe::Webhook.construct_event(payload, sig_header, webhook_secret)
          else
            data = JSON.parse(payload, symbolize_names: true)
            Stripe::Event.construct_from(data)
          end
        rescue JSON::ParserError
          head :bad_request and return
        rescue Stripe::SignatureVerificationError
          head :bad_request and return
        end

        case event.type
        when "checkout.session.completed"
          handle_checkout_completed(event.data.object)
        when "customer.subscription.updated"
          StripeService.sync_subscription_from_stripe(event.data.object)
        when "customer.subscription.deleted"
          StripeService.handle_subscription_deleted(event.data.object)
        when "invoice.payment_succeeded"
          StripeService.handle_invoice_paid(event.data.object)
        when "invoice.payment_failed"
          Rails.logger.warn("[Stripe] Payment failed for invoice #{event.data.object.id}")
        end

        head :ok
      end

      private

      def handle_checkout_completed(checkout_session)
        return unless checkout_session.subscription.present?

        stripe_sub = Stripe::Subscription.retrieve(checkout_session.subscription)
        StripeService.sync_subscription_from_stripe(stripe_sub)
      end
    end
  RUBY

  # ─── BillingController ─────────────────────────────────────────────

  file "app/controllers/billing_controller.rb", <<~'RUBY'
    class BillingController < ApplicationController
      before_action :require_login

      # GET /billing — redirect to Stripe Customer Portal
      def show
        portal = StripeService.create_billing_portal_session(
          user: current_user,
          return_url: account_url
        )

        if portal
          redirect_to portal.url, allow_other_host: true
        else
          redirect_to account_path, alert: "Billing portal not available"
        end
      end

      # GET /billing/checkout — redirect to Stripe Checkout
      def checkout
        plan_slug = params[:plan] || "individual"
        plan = Plan.find_by(slug: plan_slug, active: true)

        unless plan
          redirect_to account_path, alert: "Plan not found"
          return
        end

        checkout_session = StripeService.create_checkout_session(
          user: current_user,
          plan: plan,
          success_url: account_url + "?checkout=success",
          cancel_url: account_url + "?checkout=canceled"
        )

        if checkout_session
          redirect_to checkout_session.url, allow_other_host: true
        else
          redirect_to account_path, alert: "Checkout not available. Stripe may not be configured."
        end
      end
    end
  RUBY

  # ─── Routes ────────────────────────────────────────────────────────

  route <<~RUBY
    post "webhooks/stripe", to: "webhooks#stripe"
    get "billing", to: "billing#show"
    get "billing/checkout", to: "billing#checkout"
  RUBY

  # ─── Patch RegistrationsController ─────────────────────────────────
  # Overwrite to: create user → Stripe customer → redirect to Checkout
  # Falls back to direct subscription if Stripe not configured.
  # Handles multi-tenant case via defined?(Tenant).

  file "app/controllers/registrations_controller.rb", <<~'RUBY'
    class RegistrationsController < ApplicationController
      skip_before_action :require_login, only: [:new, :create], raise: false

      def new
        redirect_to root_path if current_user
        @user = User.new
      end

      def create
        @user = User.new(user_params)
        if @user.save
          plan = Plan.find_by(slug: "individual", active: true)

          # Create Stripe Customer (no-op if Stripe not configured)
          StripeService.create_customer(@user) if StripeService.stripe_configured?

          # Multi-tenant: auto-create personal tenant
          if defined?(Tenant)
            tenant = Tenant.create!(
              name: @user.name,
              slug: "user-#{@user.id}",
              tier: "individual"
            )
            TenantMembership.create!(user: @user, tenant: tenant, role: "admin")
          end

          # If Stripe is configured and plan has a price, redirect to Checkout
          if StripeService.stripe_configured? && plan&.stripe_price_id.present?
            session[:user_id] = @user.id

            checkout_session = StripeService.create_checkout_session(
              user: @user,
              plan: plan,
              success_url: account_url + "?checkout=success",
              cancel_url: account_url + "?checkout=canceled"
            )

            if checkout_session
              redirect_to checkout_session.url, allow_other_host: true
              return
            end
          end

          # Fallback: create subscription directly (dev mode / Stripe not configured)
          if plan
            @user.subscriptions.create!(
              plan: plan,
              status: "active",
              current_period_start: Time.current,
              current_period_end: Time.current + 1.month,
              tokens_used: 0
            )

            if defined?(TenantSubscription) && defined?(tenant) && tenant
              TenantSubscription.create!(
                tenant: tenant,
                plan: plan,
                status: "active",
                current_period_start: Time.current,
                current_period_end: Time.current + 1.month,
                tokens_used: 0
              )
            end
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

  # ─── Patch MeteringService ─────────────────────────────────────────
  # Skip maybe_reset_period! when stripe_subscription_id is present
  # (Stripe webhook handles period resets via invoice.payment_succeeded)

  inject_into_file "app/services/metering_service.rb",
    after: "return if subscription.current_period_end > Time.current\n" do
    <<-'RUBY'
    # Skip manual reset for Stripe-managed subscriptions —
    # invoice.payment_succeeded webhook handles period resets
    return if subscription.respond_to?(:stripe_subscription_id) &&
              subscription.stripe_subscription_id.present?
RUBY
  end

  # ─── Patch account view ────────────────────────────────────────────
  # Add "Manage Billing" link for subscribed users, "Subscribe Now" for others

  gsub_file "app/views/account/show.html.erb",
    '<p>No active subscription.</p>',
    <<~'ERB'.strip
      <p>No active subscription.</p>
          <% if StripeService.stripe_configured? %>
            <%= link_to "Subscribe Now", billing_checkout_path, class: "auth-form__submit", style: "display: inline-block; text-align: center; text-decoration: none; margin-top: 8px; padding: 10px 20px;" %>
          <% end %>
    ERB

  inject_into_file "app/views/account/show.html.erb",
    before: "    </div>\n  <% else %>" do
    <<-'ERB'
      <% if StripeService.stripe_configured? && @subscription.stripe_subscription_id.present? %>
      <div class="account-detail" style="margin-top: 12px;">
        <%= link_to "Manage Billing", billing_path, class: "auth-form__submit", style: "display: inline-block; text-align: center; text-decoration: none; padding: 10px 20px;" %>
      </div>
      <% end %>
ERB
  end

  # ─── Seeds: add Stripe placeholders to Plan records ────────────────

  append_to_file "db/seeds.rb", <<~'RUBY'

    # --- Stripe Billing ---

    # Update plans with Stripe IDs from ENV (set these after creating products in Stripe Dashboard)
    {
      "individual" => { product: "STRIPE_PRODUCT_INDIVIDUAL", price: "STRIPE_PRICE_INDIVIDUAL" },
      "power_user" => { product: "STRIPE_PRODUCT_POWER_USER", price: "STRIPE_PRICE_POWER_USER" },
      "group"      => { product: "STRIPE_PRODUCT_GROUP",      price: "STRIPE_PRICE_GROUP" }
    }.each do |slug, env_keys|
      plan = Plan.find_by(slug: slug)
      next unless plan

      product_id = ENV[env_keys[:product]]
      price_id = ENV[env_keys[:price]]

      if product_id.present? || price_id.present?
        plan.update!(
          stripe_product_id: product_id.presence,
          stripe_price_id: price_id.presence
        )
        puts "#{plan.name} plan updated with Stripe IDs"
      end
    end
  RUBY
end
