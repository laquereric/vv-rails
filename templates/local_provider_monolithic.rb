# vv-rails local_provider template
#
# Generates a minimal Rails app that bridges VvPlugin ActionCable events
# to a co-located Ollama instance. No cloud keys, no browser WebGPU.
# Handles llm:request → Ollama HTTP → llm:response over ActionCable.
#
# Usage:
#   rails new myapp -m vendor/vv-rails/templates/local_provider.rb
#

# --- Gems ---

gem "vv-rails", path: "vendor/vv-rails/engine"
gem "vv-browser-manager", path: "vendor/vv-browser-manager/engine"
gem "rails_event_store"
gem "rack-cors"

# --- vv:install (inlined — creates initializer and mounts engine) ---

initializer "vv_rails.rb", <<~RUBY
  Vv::Rails.configure do |config|
    config.channel_prefix = "vv"
    config.cable_url = ENV.fetch("VV_CABLE_URL", "ws://localhost:3004/cable")
  end

  Rails.configuration.to_prepare do
    Rails.configuration.event_store = RailsEventStore::Client.new
  end

  # --- Request counter (in-memory, resets on restart) ---

  module VvLocalProvider
    mattr_accessor :request_count
    self.request_count = 0
  end

  # --- EventBus: llm:request → Ollama → llm:response ---

  Vv::Rails::EventBus.on("llm:request") do |data, context|
    channel = context[:channel]
    model = data["model"] || "llama3.2"
    prompt = data["prompt"] || data["content"]
    system_prompt = data["system_prompt"]

    messages = []
    messages << { role: "system", content: system_prompt } if system_prompt
    messages << { role: "user", content: prompt }

    require "net/http"
    require "json"

    uri = URI("http://localhost:11434/api/chat")
    body = {
      model: model,
      messages: messages,
      stream: false,
      options: { temperature: 0.3, num_predict: 1024 }
    }

    http = Net::HTTP.new(uri.host, uri.port)
    http.read_timeout = 120
    request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
    request.body = body.to_json

    begin
      VvLocalProvider.request_count += 1
      resp = http.request(request)
      result = JSON.parse(resp.body)

      channel.emit("llm:response", {
        content: result.dig("message", "content"),
        model: model,
        input_tokens: result["prompt_eval_count"],
        output_tokens: result["eval_count"],
        duration_ms: result["total_duration"]&.then { |ns| ns / 1_000_000 },
        request_id: data["request_id"],
        correlation_id: data["correlation_id"]
      })
    rescue => e
      Rails.logger.error "[vv-local-provider] Ollama error: \#{e.message}"
      channel.emit("llm:response", {
        error: e.message,
        model: model,
        request_id: data["request_id"],
        correlation_id: data["correlation_id"]
      })
    end
  end
RUBY

after_bundle do
  # Allow browser extensions to connect via ActionCable
  environment <<~RUBY, env: :development
    config.action_cable.disable_request_forgery_protection = true
  RUBY

  environment <<~RUBY, env: :production
    config.action_cable.disable_request_forgery_protection = true
  RUBY

  # --- CORS (allow browser extension cross-origin requests) ---

  initializer "cors.rb", <<~RUBY
    Rails.application.config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins "*"
        resource "/vv/*",   headers: :any, methods: [:get, :options]
        resource "/health",  headers: :any, methods: [:get, :options]
        resource "/cable",   headers: :any, methods: [:get, :options]
      end
    end
  RUBY

  # --- Vv logo ---
  logo_src = File.join(File.dirname(__FILE__), "vv-logo.png")
  copy_file logo_src, "public/vv-logo.png" if File.exist?(logo_src)

  # --- Routes ---

  route <<~RUBY
    root "home#index"
    get "health", to: "health#show"
  RUBY

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

  # --- Health controller ---

  file "app/controllers/health_controller.rb", <<~RUBY
    require "net/http"

    class HealthController < ActionController::API
      def show
        ollama_ok, models = check_ollama
        model_loaded = models.any? { |m| m["name"]&.start_with?("llama3.2") }

        status = ollama_ok && model_loaded ? :ok : :service_unavailable
        render json: {
          status: status == :ok ? "ok" : "degraded",
          ollama: ollama_ok ? "reachable" : "unreachable",
          model: model_loaded ? "llama3.2" : "not_loaded",
          available_models: models.map { |m| m["name"] }
        }, status: status
      end

      private

      def check_ollama
        uri = URI("http://localhost:11434/api/tags")
        resp = Net::HTTP.get(uri)
        data = JSON.parse(resp)
        [true, data["models"] || []]
      rescue
        [false, []]
      end
    end
  RUBY

  # --- Home controller ---

  file "app/controllers/home_controller.rb", <<~RUBY
    require "net/http"

    class HomeController < ApplicationController
      def index
        @ollama_ok, @models = check_ollama
        @model_loaded = @models.any? { |m| m["name"]&.start_with?("llama3.2") }
        @request_count = defined?(VvLocalProvider) ? VvLocalProvider.request_count : 0
      end

      private

      def check_ollama
        uri = URI("http://localhost:11434/api/tags")
        resp = Net::HTTP.get(uri)
        data = JSON.parse(resp)
        [true, data["models"] || []]
      rescue
        [false, []]
      end
    end
  RUBY

  # --- Layout ---

  remove_file "app/views/layouts/application.html.erb"
  file "app/views/layouts/application.html.erb", <<~'ERB'
    <!DOCTYPE html>
    <html>
      <head>
        <title><%= content_for(:title) || "Vv Local Provider" %></title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="icon" href="/icon.png" type="image/png">
        <%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
        <%= javascript_importmap_tags %>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; background: #f5f5f5; color: #333; }
          .vv-header { background: #1a1a2e; padding: 12px 24px; display: flex; align-items: center; }
          .vv-header__logo { height: 40px; }
          .vv-main { max-width: 800px; margin: 0 auto; padding: 24px; }
        </style>
      </head>
      <body>
        <header class="vv-header">
          <a href="/"><img src="/vv-logo.png" alt="Vv" class="vv-header__logo"></a>
        </header>
        <main class="vv-main">
          <%= yield %>
        </main>
      </body>
    </html>
  ERB

  # --- Home view ---

  file "app/views/home/index.html.erb", <<~'ERB'
    <div style="text-align: center; padding: 40px 20px;">
      <img src="/vv-logo.png" alt="Vv" style="max-width: 400px; width: 100%; margin-bottom: 24px;">
      <h1 style="font-size: 24px; color: #1a1a2e; margin-bottom: 8px;">Vv Local Provider</h1>
      <p style="color: #666; margin-bottom: 32px;">Local LLM inference via Ollama</p>

      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; text-align: left;">
        <div style="background: white; border-radius: 8px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
          <div style="font-size: 13px; color: #999; text-transform: uppercase; margin-bottom: 8px;">Ollama</div>
          <div style="font-size: 18px; font-weight: 600; color: <%= @ollama_ok ? '#28a745' : '#dc3545' %>;">
            <%= @ollama_ok ? 'Connected' : 'Unreachable' %>
          </div>
        </div>

        <div style="background: white; border-radius: 8px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
          <div style="font-size: 13px; color: #999; text-transform: uppercase; margin-bottom: 8px;">Model</div>
          <div style="font-size: 18px; font-weight: 600; color: <%= @model_loaded ? '#28a745' : '#ffc107' %>;">
            <%= @model_loaded ? 'llama3.2 ready' : 'Not loaded' %>
          </div>
        </div>

        <div style="background: white; border-radius: 8px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
          <div style="font-size: 13px; color: #999; text-transform: uppercase; margin-bottom: 8px;">Requests</div>
          <div style="font-size: 18px; font-weight: 600;"><%= @request_count %></div>
        </div>
      </div>

      <% if @models.any? %>
        <div style="margin-top: 24px; background: white; border-radius: 8px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); text-align: left;">
          <div style="font-size: 13px; color: #999; text-transform: uppercase; margin-bottom: 12px;">Available Models</div>
          <% @models.each do |m| %>
            <div style="padding: 6px 0; border-bottom: 1px solid #eee; font-family: monospace; font-size: 14px;">
              <%= m["name"] %>
              <span style="color: #999; font-size: 12px;">(<%= number_to_human_size(m["size"].to_i) rescue m["size"] %>)</span>
            </div>
          <% end %>
        </div>
      <% end %>

      <p style="margin-top: 24px; font-size: 14px; color: #999;">
        Cable: <code><%= ENV.fetch("VV_CABLE_URL", "ws://localhost:3004/cable") %></code>
        &middot; Config: <code>/vv/config.json</code>
        &middot; Health: <code>/health</code>
      </p>
    </div>
  ERB

  # --- RES migration (required by vv-browser-manager event classes) ---

  generate "rails_event_store_active_record:migration"

  say ""
  say "vv-local-provider app generated!", :green
  say "  Status:        GET /"
  say "  Health:        GET /health"
  say "  Plugin config: GET /vv/config.json"
  say "  Cable:         ws://localhost:3004/cable"
  say ""
  say "Requires Ollama running on localhost:11434 with llama3.2"
  say ""
  say "Next steps:"
  say "  1. rails db:prepare"
  say "  2. ollama pull llama3.2 (if not already)"
  say "  3. rails server -p 3004"
  say ""
end
