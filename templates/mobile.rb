# vv-rails mobile template
#
# Generates a mobile-optimized chat UI that connects to a vv-host backend
# for LLM inference, with PWA support and session sync via Action Cable.
#
# Usage:
#   rails new myapp -m vendor/vv-rails/templates/mobile.rb
#

# --- Gems ---

gem "vv-rails", path: "vendor/vv-rails"
gem "vv-browser-manager", path: "vendor/vv-browser-manager"

# --- vv:install (inlined — creates initializer and mounts engine) ---

initializer "vv_rails.rb", <<~RUBY
  Vv::Rails.configure do |config|
    config.channel_prefix = "vv"
    # config.cable_url = "ws://localhost:3000/cable"
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

  # --- Routes (engine auto-mounts at /vv via initializer) ---

  route <<~RUBY
    get "settings", to: "settings#index"
    resources :sessions, only: [:new, :create]
    get "chat/:session_id", to: "chat#show", as: :chat_session
    root "chat#index"
  RUBY

  # --- Host configuration initializer ---

  file "config/initializers/vv_host.rb", <<~RUBY
    Rails.application.config.x.vv_host = ActiveSupport::OrderedOptions.new
    Rails.application.config.x.vv_host.url = ENV.fetch("VV_HOST_URL", "http://localhost:3000")
    Rails.application.config.x.vv_host.cable_url = ENV.fetch("VV_HOST_CABLE_URL", "ws://localhost:3000/cable")
  RUBY

  # --- ChatController ---

  file "app/controllers/chat_controller.rb", <<~RUBY
    class ChatController < ApplicationController
      def index
        # Session list — in a full implementation, fetch from vv-host API
        @sessions = []
      end

      def show
        @session_id = params[:session_id]
        @host_cable_url = Rails.application.config.x.vv_host.cable_url
      end
    end
  RUBY

  # --- SessionsController ---

  file "app/controllers/sessions_controller.rb", <<~RUBY
    class SessionsController < ApplicationController
      def new
      end

      def create
        # In a full implementation, POST to vv-host /api/sessions
        # For now, redirect with a placeholder session ID
        redirect_to chat_session_path(session_id: SecureRandom.uuid)
      end
    end
  RUBY

  # --- SettingsController ---

  file "app/controllers/settings_controller.rb", <<~RUBY
    class SettingsController < ApplicationController
      def index
        @host_url = Rails.application.config.x.vv_host.url
      end
    end
  RUBY

  # --- Mobile-optimized layout ---

  remove_file "app/views/layouts/application.html.erb"
  file "app/views/layouts/application.html.erb", <<~'ERB'
    <!DOCTYPE html>
    <html>
      <head>
        <title><%= content_for(:title) || "Vv Mobile" %></title>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes">
        <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
        <meta name="mobile-web-app-capable" content="yes">
        <meta name="theme-color" content="#007bff">
        <link rel="manifest" href="/manifest.json">
        <link rel="icon" href="/icon.png" type="image/png">
        <link rel="apple-touch-icon" href="/icon.png">
        <%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
        <%= javascript_importmap_tags %>
      </head>

      <body data-controller="offline">
        <header class="mobile-header">
          <nav class="mobile-nav">
            <a href="/" class="mobile-nav__brand"><img src="/vv-logo.png" alt="Vv" style="height: 28px;"></a>
            <div class="mobile-nav__status">
              <span class="mobile-nav__connectivity" data-offline-target="indicator">Online</span>
            </div>
            <a href="/settings" class="mobile-nav__settings">&#9881;</a>
          </nav>
        </header>

        <main class="mobile-main">
          <%= yield %>
        </main>
      </body>
    </html>
  ERB

  # --- Chat index (session list) ---

  file "app/views/chat/index.html.erb", <<~'ERB'
    <div class="session-list">
      <div class="session-list__header">
        <h1 class="session-list__title">Conversations</h1>
        <%= link_to "New Chat", new_session_path, class: "session-list__new-btn" %>
      </div>

      <% if @sessions.empty? %>
        <div class="session-list__empty">
          <p>No conversations yet.</p>
          <%= link_to "Start a new chat", new_session_path %>
        </div>
      <% else %>
        <% @sessions.each do |session| %>
          <%= link_to chat_session_path(session_id: session[:id]), class: "session-card" do %>
            <div class="session-card__title"><%= session[:title] %></div>
            <div class="session-card__meta"><%= session[:updated_at] %></div>
          <% end %>
        <% end %>
      <% end %>
    </div>
  ERB

  # --- Chat show (active conversation) ---

  file "app/views/chat/show.html.erb", <<~'ERB'
    <div class="mobile-chat"
         data-controller="chat session-sync"
         data-session-sync-session-id-value="<%= @session_id %>"
         data-session-sync-cable-url-value="<%= @host_cable_url %>">

      <div class="mobile-chat__messages" data-chat-target="messages">
        <div class="mobile-chat__message mobile-chat__message--system">Connected to session</div>
      </div>

      <div class="mobile-chat__input-bar">
        <input type="text"
               class="mobile-chat__input"
               placeholder="Type a message..."
               data-chat-target="input"
               data-action="keydown->chat#sendMessage">
        <button class="mobile-chat__send"
                data-action="click->chat#sendMessage">Send</button>
      </div>
    </div>
  ERB

  # --- New session view ---

  file "app/views/sessions/new.html.erb", <<~'ERB'
    <div class="new-session">
      <h1 class="new-session__title">New Conversation</h1>
      <%= form_with url: sessions_path, method: :post, class: "new-session__form" do |f| %>
        <input type="text" name="title" placeholder="Conversation title..." class="new-session__input" required>
        <button type="submit" class="new-session__submit">Start Chat</button>
      <% end %>
    </div>
  ERB

  # --- Settings view ---

  file "app/views/settings/index.html.erb", <<~'ERB'
    <div class="settings">
      <h1 class="settings__title">Settings</h1>

      <div class="settings__section">
        <h2 class="settings__section-title">Host Connection</h2>
        <div class="settings__field">
          <label class="settings__label">Host URL</label>
          <div class="settings__value"><%= @host_url %></div>
        </div>
        <p class="settings__hint">Set VV_HOST_URL environment variable to change.</p>
      </div>
    </div>
  ERB

  # --- Stimulus: chat controller ---

  file "app/javascript/controllers/chat_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["messages", "input"]

      connect() {
        this.scrollToBottom()
      }

      sendMessage(event) {
        if (event.type === "keydown" && event.key !== "Enter") return
        const message = this.inputTarget.value.trim()
        if (!message) return

        this.addMessage("user", message)
        this.inputTarget.value = ""

        // Dispatch to session-sync controller for relay to host
        this.dispatch("send", { detail: { content: message } })
      }

      addMessage(role, content) {
        const div = document.createElement("div")
        div.className = `mobile-chat__message mobile-chat__message--${role}`
        div.textContent = content
        this.messagesTarget.appendChild(div)
        this.scrollToBottom()
      }

      receiveMessage(event) {
        const { role, content } = event.detail
        this.addMessage(role, content)
      }

      scrollToBottom() {
        this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
      }
    }
  JS

  # --- Stimulus: session-sync controller ---

  file "app/javascript/controllers/session_sync_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static values = {
        sessionId: String,
        cableUrl: String
      }

      connect() {
        this.connectCable()
        this.element.addEventListener("chat:send", this.handleSend.bind(this))
      }

      disconnect() {
        if (this.subscription) this.subscription.unsubscribe()
        this.element.removeEventListener("chat:send", this.handleSend.bind(this))
      }

      connectCable() {
        if (!this.sessionIdValue) return

        // Connect to vv-host Action Cable
        this.consumer = ActionCable.createConsumer(this.cableUrlValue)
        this.subscription = this.consumer.subscriptions.create(
          { channel: "VvRelayChannel", session_id: this.sessionIdValue },
          {
            received: (data) => this.handleReceived(data),
            connected: () => console.log("Session sync connected"),
            disconnected: () => console.log("Session sync disconnected")
          }
        )
      }

      handleSend(event) {
        const { content } = event.detail
        if (this.subscription) {
          this.subscription.send({ event: "message", data: { role: "user", content: content } })
        }
      }

      handleReceived(data) {
        if (data.event === "message:new") {
          const chatController = this.element.querySelector("[data-controller~=chat]")
          if (chatController) {
            chatController.dispatchEvent(new CustomEvent("chat:receiveMessage", {
              detail: { role: data.data.role, content: data.data.content }
            }))
          }
        }
      }
    }
  JS

  # --- Stimulus: offline controller ---

  file "app/javascript/controllers/offline_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["indicator"]

      connect() {
        this.updateStatus()
        window.addEventListener("online", () => this.updateStatus())
        window.addEventListener("offline", () => this.updateStatus())
        this.registerServiceWorker()
      }

      updateStatus() {
        const online = navigator.onLine
        if (this.hasIndicatorTarget) {
          this.indicatorTarget.textContent = online ? "Online" : "Offline"
          this.indicatorTarget.classList.toggle("mobile-nav__connectivity--offline", !online)
        }
      }

      registerServiceWorker() {
        if ("serviceWorker" in navigator) {
          navigator.serviceWorker.register("/service-worker.js").catch(() => {})
        }
      }
    }
  JS

  # --- PWA manifest ---

  file "public/manifest.json", <<~JSON
    {
      "name": "Vv Mobile",
      "short_name": "Vv",
      "start_url": "/",
      "display": "standalone",
      "background_color": "#ffffff",
      "theme_color": "#007bff",
      "icons": [
        { "src": "/icon.png", "sizes": "192x192", "type": "image/png" },
        { "src": "/icon-512.png", "sizes": "512x512", "type": "image/png" }
      ]
    }
  JSON

  # --- Service worker scaffold ---

  file "public/service-worker.js", <<~JS
    const CACHE_NAME = "vv-mobile-v1"
    const PRECACHE_URLS = ["/", "/manifest.json"]

    self.addEventListener("install", (event) => {
      event.waitUntil(
        caches.open(CACHE_NAME).then((cache) => cache.addAll(PRECACHE_URLS))
      )
    })

    self.addEventListener("fetch", (event) => {
      if (event.request.method !== "GET") return

      event.respondWith(
        fetch(event.request)
          .then((response) => {
            const clone = response.clone()
            caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone))
            return response
          })
          .catch(() => caches.match(event.request))
      )
    })
  JS

  # --- Mobile CSS ---

  file "app/assets/stylesheets/mobile.css", <<~CSS
    /* Reset & Base */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    html { font-size: 16px; -webkit-text-size-adjust: 100%; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f5f5f5; color: #333; min-height: 100vh; min-height: -webkit-fill-available; padding-top: env(safe-area-inset-top); padding-bottom: env(safe-area-inset-bottom); }

    /* Header */
    .mobile-header { position: sticky; top: 0; z-index: 100; background: #007bff; color: white; padding: 0 16px; padding-top: env(safe-area-inset-top); }
    .mobile-nav { display: flex; align-items: center; height: 56px; }
    .mobile-nav__brand { color: white; text-decoration: none; font-size: 20px; font-weight: 700; }
    .mobile-nav__status { flex: 1; text-align: center; }
    .mobile-nav__connectivity { font-size: 12px; opacity: 0.8; }
    .mobile-nav__connectivity--offline { color: #ffc107; font-weight: 600; }
    .mobile-nav__settings { color: white; text-decoration: none; font-size: 20px; }

    /* Main */
    .mobile-main { padding: 16px; max-width: 600px; margin: 0 auto; }

    /* Session List */
    .session-list__header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
    .session-list__title { font-size: 24px; }
    .session-list__new-btn { background: #007bff; color: white; padding: 10px 20px; border-radius: 8px; text-decoration: none; font-size: 16px; }
    .session-list__empty { text-align: center; padding: 40px 0; color: #666; }
    .session-list__empty a { color: #007bff; }
    .session-card { display: block; background: white; border-radius: 8px; padding: 16px; margin-bottom: 8px; text-decoration: none; color: #333; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
    .session-card__title { font-weight: 600; margin-bottom: 4px; }
    .session-card__meta { font-size: 13px; color: #999; }

    /* Mobile Chat */
    .mobile-chat { display: flex; flex-direction: column; height: calc(100vh - 56px - 32px - env(safe-area-inset-top) - env(safe-area-inset-bottom)); }
    .mobile-chat__messages { flex: 1; overflow-y: auto; -webkit-overflow-scrolling: touch; padding: 8px 0; }
    .mobile-chat__message { padding: 10px 14px; margin-bottom: 8px; border-radius: 16px; max-width: 85%; font-size: 15px; line-height: 1.4; word-wrap: break-word; }
    .mobile-chat__message--user { background: #007bff; color: white; margin-left: auto; border-bottom-right-radius: 4px; }
    .mobile-chat__message--assistant { background: white; color: #333; border-bottom-left-radius: 4px; box-shadow: 0 1px 2px rgba(0,0,0,0.1); }
    .mobile-chat__message--system { background: transparent; color: #999; text-align: center; font-size: 13px; font-style: italic; }
    .mobile-chat__input-bar { display: flex; gap: 8px; padding: 8px 0; padding-bottom: env(safe-area-inset-bottom); }
    .mobile-chat__input { flex: 1; padding: 12px 16px; border: 1px solid #ddd; border-radius: 24px; font-size: 16px; outline: none; background: white; }
    .mobile-chat__input:focus { border-color: #007bff; }
    .mobile-chat__send { padding: 12px 20px; background: #007bff; color: white; border: none; border-radius: 24px; font-size: 16px; cursor: pointer; min-width: 70px; }
    .mobile-chat__send:active { background: #0056b3; }

    /* New Session */
    .new-session { padding: 20px 0; }
    .new-session__title { font-size: 24px; margin-bottom: 20px; }
    .new-session__form { display: flex; flex-direction: column; gap: 12px; }
    .new-session__input { padding: 12px 16px; border: 1px solid #ddd; border-radius: 8px; font-size: 16px; }
    .new-session__submit { padding: 14px; background: #007bff; color: white; border: none; border-radius: 8px; font-size: 16px; cursor: pointer; }

    /* Settings */
    .settings { padding: 20px 0; }
    .settings__title { font-size: 24px; margin-bottom: 20px; }
    .settings__section { background: white; border-radius: 8px; padding: 16px; margin-bottom: 16px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
    .settings__section-title { font-size: 18px; margin-bottom: 12px; }
    .settings__field { margin-bottom: 8px; }
    .settings__label { font-size: 13px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; }
    .settings__value { font-size: 15px; font-family: monospace; padding: 8px 0; }
    .settings__hint { font-size: 13px; color: #999; margin-top: 8px; }
  CSS

  say ""
  say "vv-mobile app generated!", :green
  say "  Chat:     GET /"
  say "  Session:  GET /chat/:session_id"
  say "  Settings: GET /settings"
  say "  PWA:      /manifest.json, /service-worker.js"
  say ""
  say "Next steps:"
  say "  1. Set VV_HOST_URL and VV_HOST_CABLE_URL env vars"
  say "  2. Add app icons: public/icon.png (192x192), public/icon-512.png (512x512)"
  say "  3. rails server"
  say ""
end
