# vv-rails example template
#
# Generates an example app that detects the Vv browser plugin.
# Without plugin: displays an empty app frame with "Your App Here".
# With plugin: adds a chat input; typing opens a sidebar, sending
# opens it fully and relays to the LLM via the plugin.
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

      <!-- Chat input — shown only when plugin detected -->
      <div class="chat-bar chat-bar--hidden" data-vv-app-target="chatBar">
        <input type="text"
               class="chat-bar__input"
               placeholder="Message the AI..."
               data-vv-app-target="input"
               data-action="input->vv-app#onInput keydown->vv-app#onKeydown"
               autocomplete="off">
        <button class="chat-bar__send"
                data-action="click->vv-app#send"
                data-vv-app-target="sendBtn">Send</button>
      </div>

      <!-- No-plugin notice -->
      <div class="no-plugin" data-vv-app-target="noPlugin">
        <p>Vv plugin not detected.</p>
        <p class="no-plugin__hint">Install the <a href="https://github.com/laquereric/vv-plugin" target="_blank">Vv Chrome Extension</a> to enable AI chat.</p>
      </div>

      <!-- Right sidebar -->
      <div class="sidebar" data-vv-app-target="sidebar">
        <div class="sidebar__header">
          <span class="sidebar__title">Vv Chat</span>
          <button class="sidebar__close" data-action="click->vv-app#closeSidebar">&times;</button>
        </div>
        <div class="sidebar__messages" data-vv-app-target="messages"></div>
        <div class="sidebar__status" data-vv-app-target="status"></div>
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
      static targets = ["frame", "chatBar", "noPlugin", "sidebar", "messages", "input", "sendBtn", "status"]

      connect() {
        this.pluginDetected = false
        this.sidebarState = "closed" // closed | peek | open
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
        this.chatBarTarget.classList.remove("chat-bar--hidden")
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
      }

      onNoPlugin() {
        this.noPluginTarget.style.display = "block"
        const status = document.getElementById("plugin-status")
        if (status) {
          status.textContent = "No Plugin"
          status.classList.add("vv-header__plugin-status--inactive")
        }
      }

      // --- Sidebar ---

      onInput() {
        const value = this.inputTarget.value
        if (value.length >= 1 && this.sidebarState === "closed") {
          this.peekSidebar()
        }
        if (value.length === 0 && this.sidebarState === "peek") {
          this.closeSidebar()
        }
      }

      onKeydown(event) {
        if (event.key === "Enter") {
          event.preventDefault()
          this.send()
        }
      }

      peekSidebar() {
        this.sidebarState = "peek"
        this.sidebarTarget.classList.add("sidebar--peek")
        this.sidebarTarget.classList.remove("sidebar--open")
      }

      openSidebar() {
        this.sidebarState = "open"
        this.sidebarTarget.classList.remove("sidebar--peek")
        this.sidebarTarget.classList.add("sidebar--open")
      }

      closeSidebar() {
        this.sidebarState = "closed"
        this.sidebarTarget.classList.remove("sidebar--peek", "sidebar--open")
      }

      // --- Chat ---

      send() {
        const message = this.inputTarget.value.trim()
        if (!message) return

        this.openSidebar()
        this.addMessage("user", message)
        this.inputTarget.value = ""

        this.setStatus("Thinking...")
        this.sendBtn = this.sendBtnTarget
        this.sendBtn.disabled = true

        // Send chat message to the plugin's background service worker
        // via postMessage → content script → chrome.runtime.sendMessage
        window.postMessage({
          type: "vv:chat",
          content: message
        }, "*")

        // Listen for the response from the plugin
        const responseHandler = (event) => {
          if (event.data?.type === "vv:chat:response") {
            window.removeEventListener("message", responseHandler)
            this.addMessage("assistant", event.data.content)
            this.setStatus("")
            this.sendBtnTarget.disabled = false
          } else if (event.data?.type === "vv:chat:error") {
            window.removeEventListener("message", responseHandler)
            this.addMessage("system", `Error: ${event.data.error}`)
            this.setStatus("")
            this.sendBtnTarget.disabled = false
          }
        }
        window.addEventListener("message", responseHandler)

        // Timeout fallback
        setTimeout(() => {
          window.removeEventListener("message", responseHandler)
          if (this.sendBtnTarget.disabled) {
            this.addMessage("system", "No response from plugin. Is a model loaded?")
            this.setStatus("")
            this.sendBtnTarget.disabled = false
          }
        }, 30000)
      }

      addMessage(role, content) {
        const div = document.createElement("div")
        div.className = `sidebar__message sidebar__message--${role}`
        div.textContent = content
        this.messagesTarget.appendChild(div)
        this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
      }

      setStatus(text) {
        if (this.hasStatusTarget) {
          this.statusTarget.textContent = text
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

    /* Chat Bar */
    .chat-bar { display: flex; gap: 10px; width: 100%; max-width: 640px; margin-top: 20px; transition: opacity 0.3s ease, transform 0.3s ease; }
    .chat-bar--hidden { opacity: 0; pointer-events: none; transform: translateY(10px); }
    .chat-bar__input { flex: 1; padding: 14px 18px; border: 2px solid #ddd; border-radius: 28px; font-size: 16px; outline: none; background: white; transition: border-color 0.2s ease; }
    .chat-bar__input:focus { border-color: #007bff; }
    .chat-bar__send { padding: 14px 24px; background: #007bff; color: white; border: none; border-radius: 28px; font-size: 16px; cursor: pointer; font-weight: 500; transition: background 0.2s ease; }
    .chat-bar__send:hover { background: #0056b3; }
    .chat-bar__send:disabled { background: #6c757d; cursor: not-allowed; }

    /* No Plugin Notice */
    .no-plugin { display: none; text-align: center; margin-top: 20px; color: #888; font-size: 14px; }
    .no-plugin__hint { margin-top: 6px; }
    .no-plugin__hint a { color: #007bff; }

    /* Right Sidebar */
    .sidebar { position: fixed; top: 56px; right: 0; width: 380px; height: calc(100vh - 56px); background: white; box-shadow: -4px 0 20px rgba(0,0,0,0.1); transform: translateX(100%); transition: transform 0.3s ease; display: flex; flex-direction: column; z-index: 100; }
    .sidebar--peek { transform: translateX(70%); }
    .sidebar--open { transform: translateX(0); }
    .sidebar__header { display: flex; justify-content: space-between; align-items: center; padding: 16px 20px; border-bottom: 1px solid #eee; }
    .sidebar__title { font-size: 16px; font-weight: 600; color: #1a1a2e; }
    .sidebar__close { background: none; border: none; font-size: 24px; color: #999; cursor: pointer; line-height: 1; }
    .sidebar__close:hover { color: #333; }
    .sidebar__messages { flex: 1; overflow-y: auto; padding: 16px 20px; }
    .sidebar__message { margin-bottom: 12px; padding: 10px 14px; border-radius: 12px; max-width: 90%; font-size: 14px; line-height: 1.5; word-wrap: break-word; }
    .sidebar__message--user { background: #007bff; color: white; margin-left: auto; border-bottom-right-radius: 4px; }
    .sidebar__message--assistant { background: #f0f2f5; color: #333; border-bottom-left-radius: 4px; }
    .sidebar__message--system { background: transparent; color: #999; text-align: center; font-size: 13px; font-style: italic; }
    .sidebar__status { padding: 8px 20px; font-size: 13px; color: #999; min-height: 32px; }
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
