# modules/client_llama_stack.rb — Llama Stack client gem integration
#
# Depends on: base, schema_settings

gem "llama_stack_client", path: "vendor/llama_stack_client"

after_bundle do
  remove_file "app/controllers/application_controller.rb"
  file "app/controllers/application_controller.rb", <<~RUBY
    class ApplicationController < ActionController::Base
      allow_browser versions: :modern

      private

      def host_client
        @host_client ||= LlamaStackClient::Client.new(
          base_url: Setting.host_url,
          api_key: Setting.api_token
        )
      end

      def host_configured?
        Setting.api_token.present?
      end
      helper_method :host_configured?
    end
  RUBY
end
