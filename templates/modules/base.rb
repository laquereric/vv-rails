# modules/base.rb — Universal foundation (all templates)
#
# Provides: vv-rails gem, vv-browser-manager gem, ActionCable base classes,
# Vv initializer skeleton, logo asset, base layout, HomeController.
#
# Config vars (set before apply):
#   @vv_channel_prefix  — channel prefix (default: "vv")
#   @vv_cable_url       — cable URL ENV default (default: nil → commented out)
#   @vv_app_title       — <title> tag (default: "Vv")
#   @vv_app_subtitle    — home page subtitle (default: nil)


@vv_applied_modules ||= []; @vv_applied_modules << "base"

@vv_channel_prefix ||= "vv"
@vv_app_title      ||= "Vv"

# --- Gems ---

gem "vv-rails", path: "vendor/vv-rails"
gem "vv-browser-manager", path: "vendor/vv-browser-manager"

# --- Vv initializer ---

cable_url_line = if @vv_cable_url
  "  config.cable_url = ENV.fetch(\"VV_CABLE_URL\", \"#{@vv_cable_url}\")"
else
  "  # config.cable_url = \"ws://localhost:3000/cable\""
end

initializer "vv_rails.rb", <<~RUBY
  Vv::Rails.configure do |config|
    config.channel_prefix = "#{@vv_channel_prefix}"
  #{cable_url_line}
  end
RUBY

after_bundle do
  # --- Vv logo ---
  logo_src = File.join(File.dirname(__FILE__), "..", "vv-logo.png")
  copy_file logo_src, "public/vv-logo.png" if File.exist?(logo_src)

  # --- Action Cable base classes ---

  file "app/channels/application_cable/connection.rb", <<~RUBY
    module ApplicationCable
      class Connection < ActionCable::Connection::Base
      end
    end
  RUBY

  file "app/channels/application_cable/channel.rb", <<~RUBY
    module ApplicationCable
      class Channel < ActionCable::Channel::Base
      end
    end
  RUBY

  # Allow browser extensions to connect via ActionCable
  environment <<~RUBY, env: :development
    config.action_cable.disable_request_forgery_protection = true
  RUBY

  environment <<~RUBY, env: :production
    config.action_cable.disable_request_forgery_protection = true
  RUBY
end
