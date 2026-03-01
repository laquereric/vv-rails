# modules/client_llama_stack.rb — Llama Stack client gem integration
#
# Depends on: base, schema_settings


@vv_applied_modules ||= []; @vv_applied_modules << "client_llama_stack"

gem "llama_stack_client", path: "vendor/llama_stack_client"

after_bundle do
  # Exclude llama_stack_client vendor directory from Zeitwerk eager loading.
  # The gem uses its own require structure that doesn't follow Zeitwerk conventions.
  # Must go in application.rb before load_defaults so it runs before eager_load.
  inject_into_file "config/application.rb",
    before: "    config.load_defaults" do
    <<~RUBY
      # Prevent Zeitwerk from eager-loading vendored gems
      config.eager_load_paths -= Dir[Rails.root.join("vendor").to_s]
      config.autoload_paths -= Dir[Rails.root.join("vendor").to_s]
    RUBY
  end

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
