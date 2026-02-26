# vv-rails example template
#
# Generates an example app that detects the Vv browser plugin.
# Without plugin: displays an empty app frame with "Your App Here".
# With plugin: tells the plugin to show its Shadow DOM chat UI and
# routes chat messages through ActionCable via the Rails EventBus.
#
# Usage:
#   rails new myapp -m vendor/vv-rails/templates/example.rb
#

# --- Gems ---

gem "vv-rails", path: "vendor/vv-rails"

# --- vv:install (inlined — creates initializer and mounts engine) ---

initializer "vv_rails.rb", <<~RUBY
  Vv::Rails.configure do |config|
    config.channel_prefix = "vv"
  end

  Vv::Rails::EventBus.on("chat:typing") do |data, context|
    channel = context[:channel]
    page_content = data["pageContent"] || {}
    app_context = {
      "description" => "Example app — user is viewing the main page",
      "availableActions" => ["navigate", "fill form", "submit"]
    }
    channel.emit("chat:context:analyze", {
      pageContent: page_content, appContext: app_context
    })
  end

  Vv::Rails::EventBus.on("chat:context") do |data, context|
    channel = context[:channel]
    channel.emit("chat:context:display", {
      content: data["summary"] || "Analyzing...",
      label: "I see you're working on"
    })
    channel.emit("chat:context:ready", {
      systemPromptPatch: data["systemPromptPatch"]
    })
  end

  Vv::Rails::EventBus.on("chat") do |data, context|
    channel = context[:channel]
    ctx = data["systemPromptPatch"] ? "\\n\\nContext: \#{data['systemPromptPatch']}" : ""
    channel.emit("chat:response", { content: "Echo: \#{data['content']}\#{ctx}", role: "assistant" })
  end
RUBY

after_bundle do
  # --- Vv logo ---
  logo_src = File.join(File.dirname(__FILE__), "vv-logo.png")
  copy_file logo_src, "public/vv-logo.png" if File.exist?(logo_src)

  # --- Action Cable base classes (required by vv-rails engine VvChannel) ---

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

  # --- ActionCable: mount WebSocket endpoint, async adapter, allow plugin origins ---

  route 'mount ActionCable.server => "/cable"'

  remove_file "config/cable.yml"
  file "config/cable.yml", <<~YAML
    development:
      adapter: async

    test:
      adapter: test

    production:
      adapter: async
  YAML

  environment <<~RUBY, env: :production
    config.action_cable.disable_request_forgery_protection = true
  RUBY

  # --- Routes ---

  route 'root "app#index"'

  # --- AppController ---

  file "app/controllers/app_controller.rb", <<~RUBY
    class AppController < ApplicationController
      def index
      end
    end
  RUBY

  # --- View ---

  file "app/views/app/index.html.erb", <<~'ERB'
    <div class="app-page" data-controller="vv-app">
      <!-- App Frame — always visible -->
      <div class="app-frame" data-vv-app-target="frame">
        <span class="app-frame__label">Your App Here</span>
      </div>

      <!-- No-plugin notice -->
      <div class="no-plugin" data-vv-app-target="noPlugin">
        <p>Vv plugin not detected.</p>
        <p class="no-plugin__hint">Install the <a href="https://github.com/laquereric/vv-plugin" target="_blank">Vv Chrome Extension</a> to enable AI chat.</p>
      </div>
    </div>
  ERB

  # --- Layout ---

  remove_file "app/views/layouts/application.html.erb"
  file "app/views/layouts/application.html.erb", <<~'ERB'
    <!DOCTYPE html>
    <html>
      <head>
        <title><%= content_for(:title) || "Vv Example" %></title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="icon" href="/icon.png" type="image/png">
        <%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
        <%= javascript_importmap_tags %>
      </head>
      <body>
        <header class="vv-header">
          <a href="/"><img src="/vv-logo.png" alt="Vv" class="vv-header__logo"></a>
          <span class="vv-header__title">Example App</span>
          <span class="vv-header__plugin-status" id="plugin-status"></span>
        </header>
        <%= yield %>
      </body>
    </html>
  ERB

  # --- Stimulus: vv-app controller ---

  file "app/javascript/controllers/vv_app_controller.js", <<~'JS'
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["frame", "noPlugin"]

      connect() {
        this.pluginDetected = false
        this.detectPlugin()
      }

      // --- Plugin Detection ---
      // The vv content script sets data-vv-plugin="true" on <html> and
      // responds to vv:ping with vv:pong via postMessage.

      detectPlugin() {
        // Fast check: content script sets this attribute synchronously
        if (document.documentElement.getAttribute("data-vv-plugin") === "true") {
          this.onPluginFound()
          return
        }

        // Async check: send ping, wait for pong
        const handler = (event) => {
          if (event.data?.type === "vv:pong") {
            window.removeEventListener("message", handler)
            this.onPluginFound()
          }
        }
        window.addEventListener("message", handler)
        window.postMessage({ type: "vv:ping" }, "*")

        // Timeout: no plugin
        setTimeout(() => {
          window.removeEventListener("message", handler)
          if (!this.pluginDetected) this.onNoPlugin()
        }, 500)
      }

      onPluginFound() {
        this.pluginDetected = true
        this.noPluginTarget.style.display = "none"

        const status = document.getElementById("plugin-status")
        if (status) {
          status.textContent = "Plugin Active"
          status.classList.add("vv-header__plugin-status--active")
        }

        // Auto-connect to Rails Action Cable via plugin
        window.postMessage({
          type: "vv:rails:connect",
          url: "/cable",
          channel: "VvChannel",
          pageId: "example"
        }, "*")

        // Tell the plugin to show its Shadow DOM chat UI
        window.postMessage({ type: "vv:chatbox:show" }, "*")
      }

      onNoPlugin() {
        this.noPluginTarget.style.display = "block"
        const status = document.getElementById("plugin-status")
        if (status) {
          status.textContent = "No Plugin"
          status.classList.add("vv-header__plugin-status--inactive")
        }
      }
    }
  JS

  # --- CSS ---

  file "app/assets/stylesheets/vv_example.css", <<~CSS
    /* Reset */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f0f2f5; color: #333; min-height: 100vh; }

    /* Header */
    .vv-header { background: #1a1a2e; padding: 0 24px; display: flex; align-items: center; height: 56px; gap: 16px; }
    .vv-header__logo { height: 36px; }
    .vv-header__title { color: rgba(255,255,255,0.7); font-size: 15px; flex: 1; }
    .vv-header__plugin-status { font-size: 12px; padding: 4px 10px; border-radius: 12px; background: rgba(255,255,255,0.1); color: rgba(255,255,255,0.5); }
    .vv-header__plugin-status--active { background: rgba(40,167,69,0.2); color: #28a745; }
    .vv-header__plugin-status--inactive { background: rgba(220,53,69,0.2); color: #dc3545; }

    /* App Page */
    .app-page { display: flex; flex-direction: column; align-items: center; padding: 48px 24px; min-height: calc(100vh - 56px); position: relative; }

    /* App Frame */
    .app-frame { width: 100%; max-width: 640px; height: 400px; border: 2px dashed #ccc; border-radius: 12px; display: flex; align-items: center; justify-content: center; background: white; transition: border-color 0.3s ease; }
    .app-frame__label { font-size: 24px; color: #bbb; font-weight: 300; letter-spacing: 1px; }

    /* No Plugin Notice */
    .no-plugin { display: none; text-align: center; margin-top: 20px; color: #888; font-size: 14px; }
    .no-plugin__hint { margin-top: 6px; }
    .no-plugin__hint a { color: #007bff; }
  CSS

  say ""
  say "vv-rails example app generated!", :green
  say "  App:           GET /"
  say "  Plugin config: GET /vv/config.json"
  say ""
  say "Next steps:"
  say "  1. Install the Vv Chrome Extension"
  say "  2. rails server"
  say "  3. Open http://localhost:3000"
  say "     - Without plugin: shows 'Your App Here' frame"
  say "     - With plugin: chat input appears, sidebar opens on send"
  say ""
end
