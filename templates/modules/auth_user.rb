# modules/auth_user.rb — User authentication (login, register, sessions)
#
# Provides: UserSessionsController (login/logout), RegistrationsController,
# login/register views, current_user helper, ApplicationController auth.
#
# Depends on: base, subscription


@vv_applied_modules ||= []; @vv_applied_modules << "auth_user"

after_bundle do
  # --- Routes ---

  route <<~RUBY
    get "login", to: "user_sessions#new"
    post "login", to: "user_sessions#create"
    delete "logout", to: "user_sessions#destroy"
    get "register", to: "registrations#new"
    post "register", to: "registrations#create"
    get "account", to: "account#show"
  RUBY

  # --- UserSessionsController ---

  file "app/controllers/user_sessions_controller.rb", <<~RUBY
    class UserSessionsController < ApplicationController
      skip_before_action :require_login, only: [:new, :create], raise: false

      def new
        redirect_to root_path if current_user
      end

      def create
        user = User.find_by("lower(email) = ?", params[:email]&.downcase)
        if user&.authenticate(params[:password])
          session[:user_id] = user.id
          redirect_to root_path, notice: "Signed in"
        else
          flash.now[:alert] = "Invalid email or password"
          render :new, status: :unprocessable_entity
        end
      end

      def destroy
        session.delete(:user_id)
        redirect_to login_path, notice: "Signed out"
      end
    end
  RUBY

  # --- RegistrationsController ---

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
          # Create Individual subscription
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

  # --- AccountController ---

  file "app/controllers/account_controller.rb", <<~RUBY
    class AccountController < ApplicationController
      before_action :require_login

      def show
        @user = current_user
        @subscription = @user.active_subscription
        if @subscription
          MeteringService.maybe_reset_period!(@subscription)
        end
        @api_tokens = @user.api_tokens.order(created_at: :desc)
      end
    end
  RUBY

  # --- ApplicationController auth helpers ---
  # Append to existing ApplicationController or create concern

  file "app/controllers/concerns/authentication.rb", <<~RUBY
    module Authentication
      extend ActiveSupport::Concern

      included do
        helper_method :current_user, :logged_in?
      end

      private

      def current_user
        return @current_user if defined?(@current_user)
        @current_user = User.find_by(id: session[:user_id]) if session[:user_id]
      end

      def logged_in?
        current_user.present?
      end

      def require_login
        unless logged_in?
          redirect_to login_path, alert: "Please sign in"
        end
      end
    end
  RUBY

  # --- Login view ---

  file "app/views/user_sessions/new.html.erb", <<~'ERB'
    <div class="auth-page">
      <div class="auth-card">
        <h1 class="auth-card__title">Sign In</h1>

        <% if flash[:alert] %>
          <div class="auth-card__error"><%= flash[:alert] %></div>
        <% end %>

        <%= form_with url: login_path, method: :post, class: "auth-form" do %>
          <div class="auth-form__field">
            <label for="email">Email</label>
            <input type="email" name="email" id="email" placeholder="you@example.com" required autofocus>
          </div>

          <div class="auth-form__field">
            <label for="password">Password</label>
            <input type="password" name="password" id="password" placeholder="Password" required>
          </div>

          <button type="submit" class="auth-form__submit">Sign In</button>
        <% end %>

        <div class="auth-card__footer">
          Don't have an account? <%= link_to "Register", register_path %>
        </div>
      </div>
    </div>
  ERB

  # --- Register view ---

  file "app/views/registrations/new.html.erb", <<~'ERB'
    <div class="auth-page">
      <div class="auth-card">
        <h1 class="auth-card__title">Create Account</h1>

        <% if @user.errors.any? %>
          <div class="auth-card__error">
            <% @user.errors.full_messages.each do |msg| %>
              <p><%= msg %></p>
            <% end %>
          </div>
        <% end %>

        <%= form_with model: @user, url: register_path, method: :post, class: "auth-form" do |f| %>
          <div class="auth-form__field">
            <%= f.label :name %>
            <%= f.text_field :name, placeholder: "Your name", required: true, autofocus: true %>
          </div>

          <div class="auth-form__field">
            <%= f.label :email %>
            <%= f.email_field :email, placeholder: "you@example.com", required: true %>
          </div>

          <div class="auth-form__field">
            <%= f.label :password %>
            <%= f.password_field :password, placeholder: "Password (min 8 chars)", required: true %>
          </div>

          <div class="auth-form__field">
            <%= f.label :password_confirmation, "Confirm Password" %>
            <%= f.password_field :password_confirmation, placeholder: "Confirm password", required: true %>
          </div>

          <button type="submit" class="auth-form__submit">Create Account</button>
        <% end %>

        <div class="auth-card__footer">
          Already have an account? <%= link_to "Sign in", login_path %>
        </div>
      </div>
    </div>
  ERB

  # --- Account view ---

  file "app/views/account/show.html.erb", <<~'ERB'
    <div class="account-page">
      <h1 class="account-page__title">Account</h1>

      <div class="account-section">
        <h2>Profile</h2>
        <div class="account-detail">
          <span class="account-detail__label">Name</span>
          <span class="account-detail__value"><%= @user.name %></span>
        </div>
        <div class="account-detail">
          <span class="account-detail__label">Email</span>
          <span class="account-detail__value"><%= @user.email %></span>
        </div>
      </div>

      <% if @subscription %>
        <div class="account-section">
          <h2>Subscription</h2>
          <div class="account-detail">
            <span class="account-detail__label">Plan</span>
            <span class="account-detail__value"><%= @subscription.plan.name %></span>
          </div>
          <div class="account-detail">
            <span class="account-detail__label">Status</span>
            <span class="account-detail__value account-detail__value--<%= @subscription.status %>"><%= @subscription.status.capitalize %></span>
          </div>
          <div class="account-detail">
            <span class="account-detail__label">Tokens Used</span>
            <span class="account-detail__value"><%= number_with_delimiter(@subscription.tokens_used) %> / <%= number_with_delimiter(@subscription.plan.token_limit) %></span>
          </div>
          <div class="usage-bar">
            <div class="usage-bar__fill" style="width: <%= @subscription.usage_percentage %>%"></div>
          </div>
          <div class="account-detail">
            <span class="account-detail__label">Period</span>
            <span class="account-detail__value"><%= @subscription.current_period_start&.strftime("%b %d") %> - <%= @subscription.current_period_end&.strftime("%b %d, %Y") %></span>
          </div>
        </div>
      <% else %>
        <div class="account-section">
          <h2>Subscription</h2>
          <p>No active subscription.</p>
        </div>
      <% end %>

      <% if @api_tokens.any? %>
        <div class="account-section">
          <h2>API Tokens</h2>
          <% @api_tokens.each do |token| %>
            <div class="account-detail">
              <span class="account-detail__label"><%= token.label || "API Token" %></span>
              <span class="account-detail__value account-detail__value--mono"><%= token.token_digest[0..12] %>...</span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
  ERB

  # --- Auth CSS ---

  file "app/assets/stylesheets/auth.css", <<~CSS
    /* Auth pages */
    .auth-page { display: flex; justify-content: center; align-items: center; min-height: calc(100vh - 56px); padding: 24px; }
    .auth-card { width: 100%; max-width: 420px; background: white; border-radius: 12px; padding: 36px 32px; box-shadow: 0 2px 12px rgba(0,0,0,0.08); }
    .auth-card__title { font-size: 24px; font-weight: 600; color: #1a1a2e; margin-bottom: 24px; text-align: center; }
    .auth-card__error { background: #f8d7da; color: #721c24; padding: 10px 14px; border-radius: 8px; margin-bottom: 16px; font-size: 14px; }
    .auth-card__footer { text-align: center; margin-top: 20px; font-size: 14px; color: #666; }
    .auth-card__footer a { color: #007bff; }

    .auth-form__field { margin-bottom: 16px; }
    .auth-form__field label { display: block; font-size: 14px; font-weight: 500; color: #555; margin-bottom: 6px; }
    .auth-form__field input { width: 100%; padding: 12px 14px; border: 2px solid #e0e0e0; border-radius: 8px; font-size: 15px; outline: none; transition: border-color 0.2s; }
    .auth-form__field input:focus { border-color: #667eea; }
    .auth-form__submit { width: 100%; padding: 14px; background: linear-gradient(135deg, #667eea, #764ba2); color: white; border: none; border-radius: 8px; font-size: 16px; font-weight: 600; cursor: pointer; margin-top: 8px; }
    .auth-form__submit:hover { opacity: 0.9; }

    /* Account page */
    .account-page { max-width: 600px; margin: 0 auto; padding: 24px; }
    .account-page__title { font-size: 24px; margin-bottom: 24px; }
    .account-section { background: white; border-radius: 8px; padding: 20px; margin-bottom: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.08); }
    .account-section h2 { font-size: 18px; margin-bottom: 12px; color: #1a1a2e; }
    .account-detail { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #f0f2f5; font-size: 14px; }
    .account-detail:last-child { border-bottom: none; }
    .account-detail__label { color: #888; }
    .account-detail__value { color: #333; font-weight: 500; }
    .account-detail__value--active { color: #28a745; }
    .account-detail__value--canceled { color: #dc3545; }
    .account-detail__value--expired { color: #999; }
    .account-detail__value--mono { font-family: monospace; font-size: 13px; }

    /* Usage bar */
    .usage-bar { height: 8px; background: #e9ecef; border-radius: 4px; margin: 8px 0; overflow: hidden; }
    .usage-bar__fill { height: 100%; background: linear-gradient(135deg, #667eea, #764ba2); border-radius: 4px; transition: width 0.3s; }
  CSS
end
