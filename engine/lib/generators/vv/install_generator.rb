module Vv
  class InstallGenerator < ::Rails::Generators::Base
    source_root File.expand_path("templates", __dir__)

    def create_initializer
      create_file "config/initializers/vv_rails.rb", <<~RUBY
        Vv::Rails.configure do |config|
          config.channel_prefix = "vv"
          # config.cable_url = "ws://localhost:3000/cable"
          # config.authenticate = ->(params) { User.find_by(token: params[:token]) }
          # config.on_connect = ->(channel, params) { Rails.logger.info("Vv connected: \#{params}") }
          # config.on_disconnect = ->(channel, params) { Rails.logger.info("Vv disconnected") }
        end
      RUBY
    end

    def add_cable_route
      inject_into_file "config/routes.rb", after: "Rails.application.routes.draw do\n" do
        "  mount Vv::Rails::Engine => '/vv'\n"
      end
    end

    def show_post_install
      say ""
      say "vv-rails installed!", :green
      say "  - Initializer: config/initializers/vv_rails.rb"
      say "  - Route: /vv/config.json"
      say ""
      say "Next: install the Vv Chrome extension and point it at your Rails app."
    end
  end
end
