# vv-rails mobile template
#
# Generates a mobile-optimized chat UI that connects to a vv-host backend
# via the Llama Stack API (llama_stack_client gem), with PWA support and
# streaming inference.
#
# Usage:
#   rails new myapp -m vendor/vv-rails/templates/mobile.rb
#

# --- Gems ---

gem "vv-rails", path: "vendor/vv-rails"
gem "vv-browser-manager", path: "vendor/vv-browser-manager"
gem "llama_stack_client", path: "vendor/llama_stack_client"

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

  # --- Migration for Settings ---

  generate "migration", "CreateSettings key:string:uniq value:text"

  # --- Routes (engine auto-mounts at /vv via initializer) ---

  route <<~RUBY
    get "settings", to: "settings#index"
    patch "settings", to: "settings#update"
    post "settings/connect", to: "settings#connect"
    resources :sessions, only: [:new, :create, :destroy]
    get "chat/:session_id", to: "chat#show", as: :chat_session
    post "chat/:session_id/send", to: "chat#send_message", as: :chat_session_send
    root "chat#index"
  RUBY

  # --- Setting model (key-value store for host config + API token) ---

  file "app/models/setting.rb", <<~RUBY
    class Setting < ApplicationRecord
      validates :key, presence: true, uniqueness: true

      def self.get(key, default = nil)
        find_by(key: key)&.value || default
      end

      def self.set(key, value)
        setting = find_or_initialize_by(key: key)
        setting.update!(value: value)
        value
      end

      def self.host_url
        get("host_url", ENV.fetch("VV_HOST_URL", "http://localhost:3001"))
      end

      def self.api_token
        get("api_token")
      end

      def self.default_model
        get("default_model")
      end
    end
  RUBY

  # --- ApplicationController with host client helper ---

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

  # --- ChatController ---

  file "app/controllers/chat_controller.rb", <<~RUBY
    require "net/http"

    class ChatController < ApplicationController
      include ActionController::Live

      def index
        @sessions = fetch_sessions
      rescue => e
        @sessions = []
        @error = e.message
      end

      def show
        @session_id = params[:session_id]
        @messages = fetch_conversation_items(@session_id)
        @models = fetch_models
        @default_model = Setting.default_model || @models.first&.dig("identifier")
      rescue => e
        @messages = []
        @models = []
        @error = e.message
      end

      def send_message
        session_id = params[:session_id]
        content = params[:content]
        model = params[:model] || Setting.default_model

        unless model.present?
          response.headers["Content-Type"] = "application/json"
          response.stream.write({ error: "No model selected" }.to_json)
          response.stream.close
          return
        end

        messages = build_messages(session_id, content)

        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"

        host_client.chat.completions.create(
          model: model,
          messages: messages,
          stream: true
        ) do |chunk|
          delta = chunk.dig("choices", 0, "delta", "content")
          response.stream.write("data: \#{delta.to_json}\\n\\n") if delta

          finish = chunk.dig("choices", 0, "finish_reason")
          response.stream.write("data: [DONE]\\n\\n") if finish == "stop"
        end
      rescue => e
        response.stream.write("data: \#{{ error: e.message }.to_json}\\n\\n")
      ensure
        response.stream.close
      end

      private

      def fetch_sessions
        return [] unless host_configured?

        uri = URI("\#{Setting.host_url}/api/sessions")
        req = Net::HTTP::Get.new(uri)
        req["Authorization"] = "Bearer \#{Setting.api_token}" if Setting.api_token
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.open_timeout = 5
          http.read_timeout = 10
          http.request(req)
        end
        JSON.parse(res.body)
      end

      def fetch_conversation_items(session_id)
        return [] unless host_configured?

        result = host_client.conversations.items.list(session_id.to_s)
        items = result.is_a?(Hash) ? (result["data"] || []) : (result || [])
        items.map do |item|
          {
            "role" => item["role"] || "system",
            "content" => extract_content(item)
          }
        end
      rescue
        []
      end

      def fetch_models
        return [] unless host_configured?
        host_client.models.list
      rescue
        []
      end

      def build_messages(session_id, new_content)
        history = fetch_conversation_items(session_id)
        history.map { |m| { role: m["role"], content: m["content"] } } +
          [{ role: "user", content: new_content }]
      end

      def extract_content(item)
        content = item["content"]
        if content.is_a?(Array)
          content.map { |c| c["text"] }.compact.join
        else
          content.to_s
        end
      end
    end
  RUBY

  # --- SessionsController ---

  file "app/controllers/sessions_controller.rb", <<~RUBY
    class SessionsController < ApplicationController
      def new
      end

      def create
        result = host_client.conversations.create(
          metadata: { title: params[:title].presence || "New Chat" }
        )
        session_id = result["conversation_id"] || result[:conversation_id]
        redirect_to chat_session_path(session_id: session_id)
      rescue => e
        redirect_to root_path, alert: "Failed to create session: \#{e.message}"
      end

      def destroy
        host_client.conversations.delete(params[:id].to_s)
        redirect_to root_path, notice: "Session deleted"
      rescue => e
        redirect_to root_path, alert: "Failed to delete: \#{e.message}"
      end
    end
  RUBY

  # --- SettingsController ---

  file "app/controllers/settings_controller.rb", <<~RUBY
    require "net/http"

    class SettingsController < ApplicationController
      def index
        @host_url = Setting.host_url
        @api_token = Setting.api_token
        @default_model = Setting.default_model
        @models = begin
          host_client.models.list if @api_token.present?
        rescue
          nil
        end
      end

      def update
        Setting.set("host_url", params[:host_url]) if params[:host_url].present?
        Setting.set("api_token", params[:api_token]) if params[:api_token].present?
        Setting.set("default_model", params[:default_model]) if params[:default_model].present?
        redirect_to settings_path, notice: "Settings saved"
      end

      def connect
        host_url = params[:host_url].presence || Setting.host_url
        Setting.set("host_url", host_url)

        # Request a new API token from the host
        uri = URI("\#{host_url}/api/auth/token")
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.open_timeout = 5
          http.read_timeout = 10
          http.request(req)
        end

        if res.code.to_i == 200
          data = JSON.parse(res.body)
          Setting.set("api_token", data["token"])
          redirect_to settings_path, notice: "Connected to host"
        else
          redirect_to settings_path, alert: "Connection failed: \#{res.body}"
        end
      rescue => e
        redirect_to settings_path, alert: "Connection failed: \#{e.message}"
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
        <%= csrf_meta_tags %>
        <%= csp_meta_tag %>
        <%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
        <%= javascript_importmap_tags %>
      </head>

      <body data-controller="offline mobile-nav">
        <header class="mobile-header">
          <nav class="mobile-nav">
            <% if content_for?(:back_url) %>
              <a href="<%= yield(:back_url) %>" class="mobile-nav__back" data-turbo-action="replace">&larr;</a>
            <% end %>
            <a href="/" class="mobile-nav__brand">
              <img src="/vv-logo.png" alt="Vv" style="height: 28px;">
            </a>
            <div class="mobile-nav__status">
              <span class="mobile-nav__connectivity" data-offline-target="indicator">Online</span>
            </div>
            <a href="/settings" class="mobile-nav__settings">&#9881;</a>
          </nav>
        </header>

        <% if flash[:notice] %>
          <div class="flash flash--notice"><%= flash[:notice] %></div>
        <% end %>
        <% if flash[:alert] %>
          <div class="flash flash--alert"><%= flash[:alert] %></div>
        <% end %>

        <main class="mobile-main" data-mobile-nav-target="main">
          <%= yield %>
        </main>
      </body>
    </html>
  ERB

  # --- Chat index (session list) ---

  file "app/views/chat/index.html.erb", <<~'ERB'
    <div class="session-list" data-controller="pull-refresh" data-pull-refresh-url-value="/">
      <div class="session-list__header">
        <h1 class="session-list__title">Conversations</h1>
        <%= link_to "New Chat", new_session_path, class: "session-list__new-btn" %>
      </div>

      <% unless host_configured? %>
        <div class="session-list__setup">
          <p>Connect to a Vv Host to get started.</p>
          <%= link_to "Settings", settings_path, class: "session-list__new-btn" %>
        </div>
      <% else %>
        <% if @error %>
          <div class="session-list__error"><%= @error %></div>
        <% end %>

        <% if @sessions.empty? %>
          <div class="session-list__empty">
            <p>No conversations yet.</p>
            <%= link_to "Start a new chat", new_session_path %>
          </div>
        <% else %>
          <% @sessions.each do |session| %>
            <%= link_to chat_session_path(session_id: session["id"]), class: "session-card" do %>
              <div class="session-card__title"><%= session["title"] || "Untitled" %></div>
              <div class="session-card__meta"><%= Time.parse(session["updated_at"]).strftime("%b %d, %H:%M") rescue session["updated_at"] %></div>
            <% end %>
          <% end %>
        <% end %>
      <% end %>
    </div>
  ERB

  # --- Chat show (active conversation with streaming) ---

  file "app/views/chat/show.html.erb", <<~'ERB'
    <% content_for(:back_url) { "/" } %>

    <div class="mobile-chat"
         data-controller="chat"
         data-chat-session-id-value="<%= @session_id %>"
         data-chat-send-url-value="<%= chat_session_send_path(session_id: @session_id) %>"
         data-chat-model-value="<%= @default_model %>">

      <div class="mobile-chat__messages" data-chat-target="messages">
        <% if @error %>
          <div class="mobile-chat__message mobile-chat__message--system"><%= @error %></div>
        <% end %>
        <% @messages.each do |msg| %>
          <div class="mobile-chat__message mobile-chat__message--<%= msg["role"] %>">
            <%= msg["content"] %>
          </div>
        <% end %>
      </div>

      <div class="mobile-chat__input-bar">
        <% if @models && @models.length > 1 %>
          <select class="mobile-chat__model-select" data-chat-target="modelSelect" data-action="change->chat#changeModel">
            <% @models.each do |m| %>
              <% model_id = m["identifier"] || m["api_model_id"] %>
              <option value="<%= model_id %>" <%= "selected" if model_id == @default_model %>>
                <%= m.dig("metadata", "name") || model_id %>
              </option>
            <% end %>
          </select>
        <% end %>

        <div class="mobile-chat__compose">
          <textarea class="mobile-chat__input"
                    placeholder="Type a message..."
                    rows="1"
                    data-chat-target="input"
                    data-action="keydown->chat#handleKeydown input->chat#autoResize"></textarea>
          <button class="mobile-chat__send"
                  data-chat-target="sendButton"
                  data-action="click->chat#sendMessage">Send</button>
        </div>
      </div>
    </div>
  ERB

  # --- New session view ---

  file "app/views/sessions/new.html.erb", <<~'ERB'
    <% content_for(:back_url) { "/" } %>

    <div class="new-session">
      <h1 class="new-session__title">New Conversation</h1>
      <%= form_with url: sessions_path, method: :post, class: "new-session__form" do |f| %>
        <input type="text" name="title" placeholder="Conversation title..." class="new-session__input" autofocus>
        <button type="submit" class="new-session__submit">Start Chat</button>
      <% end %>
    </div>
  ERB

  # --- Settings view ---

  file "app/views/settings/index.html.erb", <<~'ERB'
    <% content_for(:back_url) { "/" } %>

    <div class="settings">
      <h1 class="settings__title">Settings</h1>

      <div class="settings__section">
        <h2 class="settings__section-title">Host Connection</h2>
        <%= form_with url: settings_connect_path, method: :post, class: "settings__form" do %>
          <div class="settings__field">
            <label class="settings__label">Host URL</label>
            <input type="url" name="host_url" value="<%= @host_url %>" class="settings__input" placeholder="http://localhost:3001">
          </div>
          <button type="submit" class="settings__connect-btn">
            <%= @api_token ? "Reconnect" : "Connect to Host" %>
          </button>
        <% end %>

        <% if @api_token %>
          <div class="settings__connected">
            <span class="settings__connected-dot"></span> Connected
          </div>
        <% end %>
      </div>

      <% if @api_token %>
        <%= form_with url: settings_path, method: :patch, class: "settings__form" do %>
          <div class="settings__section">
            <h2 class="settings__section-title">API Token</h2>
            <div class="settings__field">
              <input type="text" name="api_token" value="<%= @api_token %>" class="settings__input settings__input--mono" readonly>
            </div>
          </div>

          <% if @models&.any? %>
            <div class="settings__section">
              <h2 class="settings__section-title">Default Model</h2>
              <div class="settings__field">
                <select name="default_model" class="settings__input">
                  <% @models.each do |m| %>
                    <% model_id = m["identifier"] || m["api_model_id"] %>
                    <option value="<%= model_id %>" <%= "selected" if model_id == @default_model %>>
                      <%= m.dig("metadata", "name") || model_id %>
                    </option>
                  <% end %>
                </select>
              </div>
            </div>
          <% end %>

          <button type="submit" class="settings__save-btn">Save</button>
        <% end %>
      <% end %>
    </div>
  ERB

  # --- Stimulus: chat controller (streaming via fetch + SSE) ---

  file "app/javascript/controllers/chat_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["messages", "input", "sendButton", "modelSelect"]
      static values = {
        sessionId: String,
        sendUrl: String,
        model: String
      }

      connect() {
        this.scrollToBottom()
      }

      handleKeydown(event) {
        if (event.key === "Enter" && !event.shiftKey) {
          event.preventDefault()
          this.sendMessage()
        }
      }

      autoResize() {
        const input = this.inputTarget
        input.style.height = "auto"
        input.style.height = Math.min(input.scrollHeight, 120) + "px"
      }

      changeModel() {
        if (this.hasModelSelectTarget) {
          this.modelValue = this.modelSelectTarget.value
        }
      }

      async sendMessage() {
        const message = this.inputTarget.value.trim()
        if (!message) return

        this.inputTarget.value = ""
        this.inputTarget.style.height = "auto"
        this.sendButtonTarget.disabled = true

        this.addMessage("user", message)

        const assistantDiv = this.addMessage("assistant", "")
        assistantDiv.classList.add("mobile-chat__message--streaming")

        try {
          const response = await fetch(this.sendUrlValue, {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-CSRF-Token": document.querySelector("[name='csrf-token']")?.content
            },
            body: JSON.stringify({ content: message, model: this.modelValue })
          })

          if (!response.ok) {
            assistantDiv.textContent = "Error: " + response.statusText
            assistantDiv.classList.add("mobile-chat__message--error")
            return
          }

          const reader = response.body.getReader()
          const decoder = new TextDecoder()
          let buffer = ""

          while (true) {
            const { done, value } = await reader.read()
            if (done) break

            buffer += decoder.decode(value, { stream: true })
            const lines = buffer.split("\\n")
            buffer = lines.pop()

            for (const line of lines) {
              if (!line.startsWith("data: ")) continue
              const data = line.slice(6)
              if (data === "[DONE]") continue

              try {
                const parsed = JSON.parse(data)
                if (parsed.error) {
                  assistantDiv.textContent += " [Error: " + parsed.error + "]"
                } else {
                  assistantDiv.textContent += parsed
                }
              } catch {
                assistantDiv.textContent += data
              }
            }
            this.scrollToBottom()
          }
        } catch (err) {
          assistantDiv.textContent = "Connection error: " + err.message
          assistantDiv.classList.add("mobile-chat__message--error")
        } finally {
          assistantDiv.classList.remove("mobile-chat__message--streaming")
          this.sendButtonTarget.disabled = false
          this.inputTarget.focus()
        }
      }

      addMessage(role, content) {
        const div = document.createElement("div")
        div.className = `mobile-chat__message mobile-chat__message--${role}`
        div.textContent = content
        this.messagesTarget.appendChild(div)
        this.scrollToBottom()
        return div
      }

      scrollToBottom() {
        requestAnimationFrame(() => {
          this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
        })
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
        this.onlineHandler = () => this.updateStatus()
        this.offlineHandler = () => this.updateStatus()
        window.addEventListener("online", this.onlineHandler)
        window.addEventListener("offline", this.offlineHandler)
        this.registerServiceWorker()
      }

      disconnect() {
        window.removeEventListener("online", this.onlineHandler)
        window.removeEventListener("offline", this.offlineHandler)
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

  # --- Stimulus: mobile-nav controller (swipe-back gesture) ---

  file "app/javascript/controllers/mobile_nav_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["main"]

      connect() {
        this.touchStartX = 0
        this.touchStartY = 0
        this.handleTouchStart = this.onTouchStart.bind(this)
        this.handleTouchEnd = this.onTouchEnd.bind(this)
        document.addEventListener("touchstart", this.handleTouchStart, { passive: true })
        document.addEventListener("touchend", this.handleTouchEnd, { passive: true })
      }

      disconnect() {
        document.removeEventListener("touchstart", this.handleTouchStart)
        document.removeEventListener("touchend", this.handleTouchEnd)
      }

      onTouchStart(event) {
        const touch = event.touches[0]
        this.touchStartX = touch.clientX
        this.touchStartY = touch.clientY
      }

      onTouchEnd(event) {
        const touch = event.changedTouches[0]
        const dx = touch.clientX - this.touchStartX
        const dy = Math.abs(touch.clientY - this.touchStartY)

        // Swipe right from left edge = go back
        if (this.touchStartX < 30 && dx > 80 && dy < 50) {
          const backLink = document.querySelector(".mobile-nav__back")
          if (backLink) {
            backLink.click()
          } else {
            window.history.back()
          }
        }
      }
    }
  JS

  # --- Stimulus: pull-to-refresh controller ---

  file "app/javascript/controllers/pull_refresh_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static values = { url: String }

      connect() {
        this.startY = 0
        this.pulling = false
        this.handleTouchStart = this.onTouchStart.bind(this)
        this.handleTouchMove = this.onTouchMove.bind(this)
        this.element.addEventListener("touchstart", this.handleTouchStart, { passive: true })
        this.element.addEventListener("touchmove", this.handleTouchMove, { passive: false })
      }

      disconnect() {
        this.element.removeEventListener("touchstart", this.handleTouchStart)
        this.element.removeEventListener("touchmove", this.handleTouchMove)
      }

      onTouchStart(event) {
        if (window.scrollY === 0) {
          this.startY = event.touches[0].clientY
          this.pulling = true
        }
      }

      onTouchMove(event) {
        if (!this.pulling) return
        const dy = event.touches[0].clientY - this.startY
        if (dy > 100) {
          this.pulling = false
          window.location.href = this.urlValue || window.location.href
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

  # --- Service worker ---

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
    .mobile-nav { display: flex; align-items: center; height: 56px; gap: 12px; }
    .mobile-nav__back { color: white; text-decoration: none; font-size: 24px; line-height: 1; }
    .mobile-nav__brand { color: white; text-decoration: none; font-size: 20px; font-weight: 700; }
    .mobile-nav__status { flex: 1; text-align: center; }
    .mobile-nav__connectivity { font-size: 12px; opacity: 0.8; }
    .mobile-nav__connectivity--offline { color: #ffc107; font-weight: 600; }
    .mobile-nav__settings { color: white; text-decoration: none; font-size: 20px; }

    /* Flash messages */
    .flash { padding: 10px 16px; font-size: 14px; text-align: center; }
    .flash--notice { background: #d4edda; color: #155724; }
    .flash--alert { background: #f8d7da; color: #721c24; }

    /* Main */
    .mobile-main { padding: 16px; max-width: 600px; margin: 0 auto; }

    /* Session List */
    .session-list__header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
    .session-list__title { font-size: 24px; }
    .session-list__new-btn { background: #007bff; color: white; padding: 10px 20px; border-radius: 8px; text-decoration: none; font-size: 16px; display: inline-block; }
    .session-list__setup { text-align: center; padding: 40px 0; color: #666; }
    .session-list__setup p { margin-bottom: 16px; }
    .session-list__error { background: #f8d7da; color: #721c24; padding: 10px; border-radius: 8px; margin-bottom: 12px; font-size: 14px; }
    .session-list__empty { text-align: center; padding: 40px 0; color: #666; }
    .session-list__empty a { color: #007bff; }
    .session-card { display: block; background: white; border-radius: 8px; padding: 16px; margin-bottom: 8px; text-decoration: none; color: #333; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
    .session-card:active { background: #f0f0f0; }
    .session-card__title { font-weight: 600; margin-bottom: 4px; }
    .session-card__meta { font-size: 13px; color: #999; }

    /* Mobile Chat */
    .mobile-chat { display: flex; flex-direction: column; height: calc(100vh - 56px - 32px - env(safe-area-inset-top) - env(safe-area-inset-bottom)); }
    .mobile-chat__messages { flex: 1; overflow-y: auto; -webkit-overflow-scrolling: touch; padding: 8px 0; }
    .mobile-chat__message { padding: 10px 14px; margin-bottom: 8px; border-radius: 16px; max-width: 85%; font-size: 15px; line-height: 1.4; word-wrap: break-word; white-space: pre-wrap; }
    .mobile-chat__message--user { background: #007bff; color: white; margin-left: auto; border-bottom-right-radius: 4px; }
    .mobile-chat__message--assistant { background: white; color: #333; border-bottom-left-radius: 4px; box-shadow: 0 1px 2px rgba(0,0,0,0.1); }
    .mobile-chat__message--system { background: transparent; color: #999; text-align: center; font-size: 13px; font-style: italic; max-width: 100%; }
    .mobile-chat__message--streaming { opacity: 0.9; }
    .mobile-chat__message--streaming::after { content: "\\25CB"; animation: blink 1s infinite; }
    .mobile-chat__message--error { background: #f8d7da; color: #721c24; }
    @keyframes blink { 50% { opacity: 0; } }

    /* Chat input */
    .mobile-chat__input-bar { padding: 8px 0; }
    .mobile-chat__model-select { width: 100%; padding: 8px 12px; border: 1px solid #ddd; border-radius: 8px; font-size: 14px; background: white; margin-bottom: 4px; }
    .mobile-chat__compose { display: flex; gap: 8px; padding-bottom: env(safe-area-inset-bottom); }
    .mobile-chat__input { flex: 1; padding: 12px 16px; border: 1px solid #ddd; border-radius: 24px; font-size: 16px; outline: none; background: white; resize: none; max-height: 120px; font-family: inherit; }
    .mobile-chat__input:focus { border-color: #007bff; }
    .mobile-chat__send { padding: 12px 20px; background: #007bff; color: white; border: none; border-radius: 24px; font-size: 16px; cursor: pointer; min-width: 70px; align-self: flex-end; }
    .mobile-chat__send:active { background: #0056b3; }
    .mobile-chat__send:disabled { background: #ccc; }

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
    .settings__field { margin-bottom: 12px; }
    .settings__label { display: block; font-size: 13px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 4px; }
    .settings__input { width: 100%; padding: 10px 12px; border: 1px solid #ddd; border-radius: 8px; font-size: 15px; }
    .settings__input--mono { font-family: monospace; font-size: 13px; }
    .settings__connect-btn { width: 100%; padding: 12px; background: #28a745; color: white; border: none; border-radius: 8px; font-size: 16px; cursor: pointer; margin-top: 8px; }
    .settings__connect-btn:active { background: #218838; }
    .settings__save-btn { width: 100%; padding: 12px; background: #007bff; color: white; border: none; border-radius: 8px; font-size: 16px; cursor: pointer; }
    .settings__connected { display: flex; align-items: center; gap: 8px; margin-top: 12px; font-size: 14px; color: #28a745; }
    .settings__connected-dot { width: 8px; height: 8px; background: #28a745; border-radius: 50%; }
    .settings__form { display: contents; }
  CSS

  say ""
  say "vv-mobile app generated!", :green
  say "  Chat:     GET /"
  say "  Session:  GET /chat/:session_id"
  say "  Send:     POST /chat/:session_id/send (SSE streaming)"
  say "  Settings: GET /settings"
  say "  PWA:      /manifest.json, /service-worker.js"
  say ""
  say "Powered by llama_stack_client — connects to Vv Host Llama Stack API"
  say ""
  say "Next steps:"
  say "  1. rails db:create db:migrate"
  say "  2. Go to /settings and connect to your Vv Host"
  say "  3. rails server -p 3002"
  say ""
end
