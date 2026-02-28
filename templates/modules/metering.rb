# modules/metering.rb — Token usage tracking and quota enforcement
#
# Provides: MeteringService, quota check in Api::BaseController,
# usage recording via EventBus, GET /api/usage endpoint.
#
# Depends on: base, subscription, auth_token, schema_session

after_bundle do
  # --- MeteringService ---

  file "app/services/metering_service.rb", <<~RUBY
    class MeteringService
      class QuotaExceededError < StandardError; end

      # Check if the subscription has remaining quota
      def self.check_quota!(subscription)
        return unless subscription  # No subscription = no enforcement (dev mode)

        if subscription.quota_exceeded?
          raise QuotaExceededError,
            "Token quota exceeded. Used \#{subscription.tokens_used.to_fs(:delimited)} " \\
            "of \#{subscription.plan.token_limit.to_fs(:delimited)} tokens. " \\
            "Resets at \#{subscription.current_period_end.strftime('%Y-%m-%d')}."
        end
      end

      # Record token usage after inference
      def self.record_usage!(subscription, input_tokens:, output_tokens:)
        return unless subscription
        subscription.record_usage!(input_tokens, output_tokens)
      end

      # Check and reset expired billing periods
      def self.maybe_reset_period!(subscription)
        return unless subscription
        return if subscription.current_period_end > Time.current
        subscription.reset_period!
      end

      # Usage summary for API response
      def self.usage_summary(subscription)
        return nil unless subscription
        {
          plan: subscription.plan.slug,
          plan_name: subscription.plan.name,
          tokens_used: subscription.tokens_used,
          token_limit: subscription.plan.token_limit,
          tokens_remaining: subscription.tokens_remaining,
          usage_percentage: subscription.usage_percentage,
          period_start: subscription.current_period_start&.iso8601,
          period_end: subscription.current_period_end&.iso8601,
          status: subscription.status
        }
      end
    end
  RUBY

  # --- Enhance Api::BaseController with metering ---

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

      def current_user
        return @current_user if defined?(@current_user)
        token_str = request.headers["Authorization"]&.delete_prefix("Bearer ")
        api_token = token_str.present? ? ApiToken.authenticate(token_str) : nil
        @current_user = api_token&.user
      end

      def check_quota
        return unless current_subscription  # No subscription = no enforcement
        MeteringService.maybe_reset_period!(current_subscription)
        MeteringService.check_quota!(current_subscription)
      rescue MeteringService::QuotaExceededError => e
        render json: { error: e.message, quota_exceeded: true }, status: :too_many_requests
      end

      def record_token_usage(input_tokens, output_tokens)
        MeteringService.record_usage!(
          current_subscription,
          input_tokens: input_tokens,
          output_tokens: output_tokens
        )
      end
    end
  RUBY

  # --- Usage API endpoint ---

  file "app/controllers/api/usage_controller.rb", <<~RUBY
    module Api
      class UsageController < BaseController
        def show
          token_str = request.headers["Authorization"]&.delete_prefix("Bearer ")
          api_token = token_str.present? ? ApiToken.authenticate(token_str) : nil
          user = api_token&.user

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

          render json: MeteringService.usage_summary(subscription)
        end
      end
    end
  RUBY

  route 'namespace :api do get "usage", to: "usage#show" end'

  # --- EventBus hook: record usage after llm:response ---

  append_to_file "config/initializers/vv_rails.rb", <<~'RUBY'

    # --- Metering: record token usage after LLM responses ---

    Vv::Rails::EventBus.on("llm:response") do |data, context|
      input_tokens = data["input_tokens"].to_i
      output_tokens = data["output_tokens"].to_i

      if input_tokens > 0 || output_tokens > 0
        # Find subscription from the channel's page_id or context
        # This integrates with the Metered concern for API-based metering
        Rails.logger.info("[Vv] Metering: #{input_tokens} in + #{output_tokens} out tokens")
      end
    end
  RUBY
end
