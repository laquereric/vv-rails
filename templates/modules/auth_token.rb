# modules/auth_token.rb — API token authentication + issuance
#
# Depends on: base


@vv_applied_modules ||= []; @vv_applied_modules << "auth_token"

gem "bcrypt", "~> 3.1"

after_bundle do
  generate "migration", "CreateApiTokens token_digest:string:index label:string expires_at:datetime"

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

  route 'namespace :api do post "auth/token", to: "auth#token" end'
end
