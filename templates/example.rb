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
    form_fields = page_content["formFields"] || {}

    # Build a human-readable summary of form state
    field_summary = form_fields.map do |name, info|
      label = info["label"] || name
      value = info["value"].to_s
      status = value.strip.empty? ? "EMPTY" : "filled in with: \#{value}"
      "  - \#{label}: \#{status}"
    end.join("\\n")

    app_context = {
      "description" => "Beneficiary designation form. The current user (John Jones) is designating a beneficiary. Fields: First Name, Last Name, and E Pluribus Unum (the national motto of the United States, meaning 'Out of many, one'). A beneficiary is a person designated to receive benefits from an account, policy, or trust. Typically this should be someone OTHER than the account holder.",
      "currentUser" => "John Jones",
      "formTitle" => "Beneficiary",
      "formFields" => form_fields,
      "formSummary" => field_summary,
      "instructions" => "When the user asks about a field, explain why it is needed in the context of a beneficiary designation. If a required field is empty, mention that it still needs to be filled in. Be helpful and concise."
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
    # No echo — the plugin routes chat to the LLM directly.
    # This handler is available for app-level hooks (logging, persistence, etc.)
    Rails.logger.info "[vv] chat received: \#{data['content']&.truncate(80)}"
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
    <div class="app-page" data-controller="vv-app" data-vv-app-current-user-value="John Jones">
      <!-- Beneficiary Form -->
      <div class="app-form" data-vv-app-target="frame">
        <h2 class="app-form__heading">Beneficiary</h2>

        <div class="app-form__field">
          <label for="first_name">First Name</label>
          <input type="text" id="first_name" name="first_name" data-field="first_name" placeholder="Enter your first name" autocomplete="off">
        </div>

        <div class="app-form__field">
          <label for="last_name">Last Name</label>
          <input type="text" id="last_name" name="last_name" data-field="last_name" placeholder="Enter your last name" autocomplete="off">
        </div>

        <div class="app-form__field">
          <label for="e_pluribus_unum">E Pluribus Unum</label>
          <input type="text" id="e_pluribus_unum" name="e_pluribus_unum" data-field="e_pluribus_unum" placeholder="Out of many, one" autocomplete="off">
        </div>

        <button type="button" class="app-form__submit" id="form-send">Send</button>
        <div class="app-form__status" id="form-status"></div>
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
          <span class="vv-header__user" id="current-user">User: John Jones</span>
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
      static values = { currentUser: String }

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

        this.setupFormSubmit()
      }

      onNoPlugin() {
        this.noPluginTarget.style.display = "block"
        const status = document.getElementById("plugin-status")
        if (status) {
          status.textContent = "No Plugin"
          status.classList.add("vv-header__plugin-status--inactive")
        }
      }

      // --- Form Submit ---
      setupFormSubmit() {
        const btn = document.getElementById("form-send")
        if (!btn) return

        // Listen for validation results from the plugin
        window.addEventListener("message", (event) => {
          if (event.source !== window) return
          if (event.data?.type !== "vv:form:validate:result") return

          const status = document.getElementById("form-status")
          const { ok, answer, explanation } = event.data

          if (ok) {
            if (status) { status.textContent = "Submitted!"; status.style.color = "#28a745" }
          } else {
            if (status) { status.textContent = "Review needed — see chat sidebar"; status.style.color = "#e67e22" }
          }
        })

        btn.addEventListener("click", () => {
          const first = document.getElementById("first_name")?.value?.trim()
          const last = document.getElementById("last_name")?.value?.trim()
          const epu = document.getElementById("e_pluribus_unum")?.value?.trim()
          const status = document.getElementById("form-status")

          if (!first || !last || !epu) {
            if (status) { status.textContent = "Please fill in all fields."; status.style.color = "#dc3545" }
            return
          }

          // Intercept: ask LLM "does this look right?" before submitting
          if (status) { status.textContent = "Validating..."; status.style.color = "#667eea" }
          btn.disabled = true

          const formTitle = "Beneficiary"
          const currentUser = this.currentUserValue || "Unknown"
          const formFields = {
            first_name: { label: "First Name", value: first },
            last_name: { label: "Last Name", value: last },
            e_pluribus_unum: { label: "E Pluribus Unum", value: epu }
          }

          window.postMessage({
            type: "vv:form:validate",
            currentUser,
            formTitle,
            formFields
          }, "*")

          // Re-enable after timeout in case plugin doesn't respond
          setTimeout(() => { btn.disabled = false }, 15000)
        })
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
    .vv-header__user { color: rgba(255,255,255,0.85); font-size: 14px; font-weight: 500; }
    .vv-header__plugin-status { font-size: 12px; padding: 4px 10px; border-radius: 12px; background: rgba(255,255,255,0.1); color: rgba(255,255,255,0.5); }
    .vv-header__plugin-status--active { background: rgba(40,167,69,0.2); color: #28a745; }
    .vv-header__plugin-status--inactive { background: rgba(220,53,69,0.2); color: #dc3545; }

    /* App Page */
    .app-page { display: flex; flex-direction: column; align-items: center; padding: 48px 24px; min-height: calc(100vh - 56px); position: relative; }

    /* Form */
    .app-form { width: 100%; max-width: 480px; background: white; border-radius: 12px; padding: 36px 32px; box-shadow: 0 2px 12px rgba(0,0,0,0.08); }
    .app-form__heading { font-size: 22px; font-weight: 600; color: #1a1a2e; margin-bottom: 28px; }
    .app-form__field { margin-bottom: 20px; }
    .app-form__field label { display: block; font-size: 14px; font-weight: 500; color: #555; margin-bottom: 6px; }
    .app-form__field input { width: 100%; padding: 12px 14px; border: 2px solid #e0e0e0; border-radius: 8px; font-size: 15px; outline: none; transition: border-color 0.2s; }
    .app-form__field input:focus { border-color: #667eea; }
    .app-form__submit { width: 100%; padding: 14px; background: linear-gradient(135deg, #667eea, #764ba2); color: white; border: none; border-radius: 8px; font-size: 16px; font-weight: 600; cursor: pointer; margin-top: 8px; transition: opacity 0.2s; }
    .app-form__submit:hover { opacity: 0.9; }
    .app-form__status { text-align: center; margin-top: 12px; font-size: 14px; color: #28a745; min-height: 20px; }

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
