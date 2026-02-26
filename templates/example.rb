# vv-rails example template
#
# Generates a browser-side LLM chat demo powered by WebGPU via WebLLM.
# All inference runs client-side — no backend LLM server required.
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
    # config.cable_url = "ws://localhost:3000/cable"
    # config.authenticate = ->(params) { User.find_by(token: params[:token]) }
    # config.on_connect = ->(channel, params) { Rails.logger.info("Vv connected: \#{params}") }
    # config.on_disconnect = ->(channel, params) { Rails.logger.info("Vv disconnected") }
  end
RUBY

after_bundle do
  # --- Routes (engine auto-mounts at /vv via initializer) ---

  route 'get "chat", to: "chat#index"'
  route 'root "chat#index"'

  # --- ChatController ---

  file "app/controllers/chat_controller.rb", <<~RUBY
    class ChatController < ApplicationController
      include ChatHelper

      def index
      end
    end
  RUBY

  # --- ChatHelper ---

  file "app/helpers/chat_helper.rb", <<~'RUBY'
    module ChatHelper
      include ActionView::Helpers::TagHelper
      include ActionView::Helpers::FormTagHelper
      include ActionView::Helpers::UrlHelper

      def web_llm_chat(
        model:         "Llama-3.1-8B-Instruct-q4f32_1-MLC",
        system_prompt: "You are a helpful AI assistant.",
        placeholder:   "Ask me anything\u2026",
        title:         "AI Assistant",
        height:        "400px",
        **html_options
      )
        content_tag(:div, {
          class: "web-llm-chat",
          data: {
            controller: "web-llm",
            "web-llm-model-value": model,
            "web-llm-system-prompt-value": system_prompt,
            "web-llm-placeholder-value": placeholder,
            "web-llm-title-value": title
          },
          style: "height: #{height};",
          **html_options
        }) do
          concat(content_tag(:h2, title, class: "web-llm-chat__title"))
          concat(content_tag(:div, "", class: "web-llm-chat__messages", style: "height: calc(#{height} - 70px);", data: { "web-llm-target": "messages" }))
          concat(content_tag(:div, class: "web-llm-chat__input") do
            concat(tag(:input, {
              type: "text",
              placeholder: placeholder,
              class: "web-llm-chat__input-field",
              data: { action: "keydown->web-llm#sendMessage" }
            }))
            concat(content_tag(:button, "Send", {
              class: "web-llm-chat__send-button",
              data: { action: "click->web-llm#sendMessage" }
            }))
          end)
        end
      end
    end
  RUBY

  # --- Chat view ---

  file "app/views/chat/index.html.erb", <<~'ERB'
    <h1>WebLLM Chat Application</h1>
    <p>Start a conversation with the AI assistant below.</p>

    <%= web_llm_chat(
      model: "SmolLM2-360M-Instruct-q4f16_1-MLC",
      system_prompt: "You are a helpful AI assistant.",
      title: "AI Chat Assistant",
      height: "600px"
    ) %>
  ERB

  # --- Layout with settings panel and browser setup modal ---

  remove_file "app/views/layouts/application.html.erb"
  file "app/views/layouts/application.html.erb", <<~'ERB'
    <!DOCTYPE html>
    <html>
      <head>
        <title><%= content_for(:title) || "Vv Chat Example" %></title>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="apple-mobile-web-app-capable" content="yes">

        <script>
          webLLMGlobal = {};
        </script>

        <script type="module">
          import * as webllm from '/js/web-llm.js';
          window.webllm = webllm;
        </script>
        <script type="module" src="/js/get_started.js"></script>

        <%= yield :head %>
        <link rel="icon" href="/icon.png" type="image/png">
        <%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>
        <%= javascript_importmap_tags %>
      </head>

      <body data-controller="chat-status">
        <!-- Settings Gear -->
        <div class="settings-gear-container">
          <button class="settings-gear" data-action="click->chat-status#toggleSettings" title="Settings">&#9881;</button>
        </div>

        <!-- Settings Panel -->
        <div class="chat-status-panel" data-chat-status-target="settingsPanel">
          <div class="chat-status-panel__content">
            <h3 class="chat-status-panel__title">Chat Settings</h3>
            <div class="chat-status-panel__section">
              <h4 class="chat-status-panel__section-title">Model Status</h4>
              <div class="chat-status-panel__status">
                <span class="chat-status-panel__indicator" data-chat-status-target="modelIndicator"></span>
                <span class="chat-status-panel__status-text" data-chat-status-target="modelStatusText">Not Loaded</span>
              </div>
            </div>
            <div class="chat-status-panel__section">
              <h4 class="chat-status-panel__section-title">Current Model</h4>
              <select class="chat-status-panel__model-select" data-chat-status-target="modelSelect" data-action="change->chat-status#modelChanged">
                <option value="SmolLM2-360M-Instruct-q4f16_1-MLC" selected>SmolLM2-360M</option>
                <option value="SmolLM2-1.7B-Instruct-q4f16_1-MLC">SmolLM2-1.7B</option>
                <option value="Phi-3.5-mini-instruct-q4f16_1-MLC">Phi-3.5-mini</option>
                <option value="Llama-3.1-8B-Instruct-q4f32_1-MLC">Llama-3.1-8B</option>
              </select>
              <div class="chat-status-panel__model-controls">
                <button class="chat-status-panel__button chat-status-panel__button--primary" data-chat-status-target="loadButton" data-action="click->chat-status#loadModel">Load Model</button>
                <button class="chat-status-panel__button chat-status-panel__button--secondary" data-chat-status-target="unloadButton" data-action="click->chat-status#unloadModel" disabled>Unload</button>
              </div>
            </div>
            <div class="chat-status-panel__section">
              <h4 class="chat-status-panel__section-title">Actions</h4>
              <div class="chat-status-panel__actions">
                <button class="chat-status-panel__button chat-status-panel__button--primary" data-action="click->chat-status#reloadChat">Reload</button>
                <button class="chat-status-panel__button chat-status-panel__button--secondary" data-action="click->chat-status#showBrowserSetup">Browser Setup</button>
                <button class="chat-status-panel__button chat-status-panel__button--warning" data-action="click->chat-status#tryAnywayLoad">Try Anyway</button>
              </div>
            </div>
          </div>
        </div>

        <!-- Browser Setup Modal -->
        <div class="browser-setup-modal" data-chat-status-target="browserSetupModal">
          <div class="browser-setup-modal__content">
            <div class="browser-setup-modal__header">
              <h2 class="browser-setup-modal__title">Browser Setup for WebGPU</h2>
              <button class="browser-setup-modal__close" data-action="click->chat-status#closeBrowserSetup">&times;</button>
            </div>
            <div class="browser-setup-modal__body">
              <div class="browser-setup-modal__section">
                <h3>Chrome/Chromium</h3>
                <ul class="browser-setup-modal__flag-list">
                  <li class="browser-setup-modal__flag-item">
                    <div class="browser-setup-modal__flag-name">Unsafe WebGPU</div>
                    <div class="browser-setup-modal__flag-description">chrome://flags/ &rarr; search "WebGPU" &rarr; Enabled</div>
                  </li>
                  <li class="browser-setup-modal__flag-item">
                    <div class="browser-setup-modal__flag-name">WebGPU Developer Features</div>
                    <div class="browser-setup-modal__flag-description">Search "WebGPU Developer" &rarr; Enabled</div>
                  </li>
                </ul>
              </div>
              <div class="browser-setup-modal__section">
                <h3>Firefox</h3>
                <ul class="browser-setup-modal__flag-list">
                  <li class="browser-setup-modal__flag-item">
                    <div class="browser-setup-modal__flag-name">dom.webgpu.enabled</div>
                    <div class="browser-setup-modal__flag-description">about:config &rarr; set to true</div>
                  </li>
                </ul>
              </div>
              <div class="browser-setup-modal__section">
                <h3>Safari</h3>
                <ul class="browser-setup-modal__flag-list">
                  <li class="browser-setup-modal__flag-item">
                    <div class="browser-setup-modal__flag-name">Safari 16.4+</div>
                    <div class="browser-setup-modal__flag-description">WebGPU available by default on macOS Ventura+ and iOS 16.4+</div>
                  </li>
                </ul>
              </div>
              <div class="browser-setup-modal__note">
                <div class="browser-setup-modal__note-title">Note</div>
                <div class="browser-setup-modal__note-text">Restart browser after changing flags. WebGPU requires a compatible GPU.</div>
              </div>
            </div>
          </div>
        </div>

        <%= yield %>
      </body>
    </html>
  ERB

  # --- Stimulus: web-llm controller ---

  file "app/javascript/controllers/web_llm_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["messages"]
      static values = {
        model: String,
        systemPrompt: String,
        placeholder: String,
        title: String,
        hidden: { type: Boolean, default: true }
      }

      webllmManager = null

      connect() {
        this.inputField = this.element.querySelector(".web-llm-chat__input-field")
        this.sendButton = this.element.querySelector(".web-llm-chat__send-button")

        if (window.WebLLMState && window.WebLLMState.isLoaded) {
          this.messagesTarget.innerHTML = "<div class='web-llm-chat__message web-llm-chat__message--system'>Status: Model Available</div>"
        } else {
          this.messagesTarget.innerHTML = "<div class='web-llm-chat__message web-llm-chat__message--system'>Status: Model Not Available</div>"
        }

        window.addEventListener("webLLMModelLoaded", this.handleModelLoaded.bind(this))
        window.addEventListener("webLLMModelUnloaded", this.handleModelUnloaded.bind(this))
        this.checkInitialModelStatus()
      }

      disconnect() {
        window.removeEventListener("webLLMModelLoaded", this.handleModelLoaded.bind(this))
        window.removeEventListener("webLLMModelUnloaded", this.handleModelUnloaded.bind(this))
      }

      handleModelLoaded(event) {
        this.modelLoaded = true
        this.webllmManager = window.getWebLLMManager()
        this.addMessage("system", `Model ready: ${event.detail.model}`)
      }

      handleModelUnloaded() {
        this.modelLoaded = false
        this.webllmManager = null
        this.addMessage("system", "Model unloaded")
      }

      checkInitialModelStatus() {
        if (window.WebLLMState && window.WebLLMState.isLoaded) {
          this.modelLoaded = true
          this.webllmManager = window.WebLLMState.manager
          this.addMessage("system", `Model ready: ${window.WebLLMState.model}`)
        }
      }

      sendMessage(event) {
        if (event.type === "keydown" && event.key !== "Enter") return
        const message = this.inputField.value.trim()
        if (!message) return

        const isModelLoaded = this.modelLoaded || (window.WebLLMState && window.WebLLMState.isLoaded)
        if (!isModelLoaded) {
          this.addMessage("system", "Please load a model first.")
          return
        }

        this.addMessage("user", message)
        this.inputField.value = ""
        this.sendButton.disabled = true
        this.sendButton.textContent = "Thinking..."

        this.webllmManager.generate(message)
          .then(response => {
            this.addMessage("assistant", response)
            this.sendButton.disabled = false
            this.sendButton.textContent = "Send"
          })
          .catch(error => {
            this.addMessage("system", `Error: ${error.message}`)
            this.sendButton.disabled = false
            this.sendButton.textContent = "Send"
          })
      }

      addMessage(role, content) {
        const messageDiv = document.createElement("div")
        messageDiv.className = `web-llm-chat__message web-llm-chat__message--${role}`
        messageDiv.textContent = content
        this.messagesTarget.appendChild(messageDiv)
        this.messagesTarget.scrollTop = this.messagesTarget.scrollHeight
      }
    }
  JS

  # --- Stimulus: chat-status controller ---

  file "app/javascript/controllers/chat_status_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      static targets = ["settingsPanel", "modelSelect", "loadButton", "unloadButton", "modelStatusText", "modelIndicator", "browserSetupModal"]

      connect() {
        setTimeout(() => {
          if (window.WebLLMManager) {
            this.webllmManager = window.getWebLLMManager()
            this.syncWithGlobalState()
          }
        }, 500)
      }

      syncWithGlobalState() {
        if (window.WebLLMState && window.WebLLMState.isLoaded) {
          this.updateModelStatus("loaded")
        }
      }

      async loadModel() {
        if (this.modelLoading) return
        this.updateModelStatus("loading")
        this.modelLoading = true

        if (!window.webllm || !window.WebLLMManager) {
          this.updateModelStatus("error")
          this.modelLoading = false
          return
        }

        const webllmManager = window.getWebLLMManager()
        const webgpuSupport = await webllmManager.checkWebGPUSupport()

        if (!webgpuSupport) {
          this.updateModelStatus("error")
          this.modelLoading = false
          setTimeout(() => this.showBrowserSetup(), 1000)
          return
        }

        try {
          await webllmManager.loadModel(this.modelSelectTarget.value)
          this.updateModelStatus("loaded")
          window.WebLLMState.model = this.modelSelectTarget.value
          window.WebLLMState.isLoaded = true
          window.WebLLMState.isLoading = false
          this.modelLoading = false
          this.notifyModelLoaded()
        } catch (error) {
          this.updateModelStatus("error")
          this.modelLoading = false
        }
      }

      unloadModel() {
        if (!window.WebLLMManager) return
        const webllmManager = window.getWebLLMManager()
        webllmManager.unloadModel()
        this.updateModelStatus("not-loaded")
        window.WebLLMState.model = null
        window.WebLLMState.isLoaded = false
        this.notifyModelUnloaded()
      }

      toggleSettings() {
        this.settingsPanelTarget.classList.toggle("chat-status-panel--visible")
      }

      updateModelStatus(status) {
        if (this.hasModelStatusTextTarget) {
          const labels = { "not-loaded": "Not Loaded", loading: "Loading...", loaded: "Loaded", error: "Error" }
          this.modelStatusTextTarget.textContent = labels[status] || status
        }
        if (this.hasModelIndicatorTarget) {
          this.modelIndicatorTarget.className = "chat-status-panel__indicator"
          if (status === "loading") this.modelIndicatorTarget.classList.add("chat-status-panel__indicator--loading")
          if (status === "loaded") this.modelIndicatorTarget.classList.add("chat-status-panel__indicator--loaded")
        }
        if (this.hasLoadButtonTarget) this.loadButtonTarget.disabled = (status === "loading" || status === "loaded")
        if (this.hasUnloadButtonTarget) this.unloadButtonTarget.disabled = (status !== "loaded")
      }

      modelChanged() {
        if (this.modelLoaded) this.updateModelStatus("not-loaded")
      }

      reloadChat() { window.location.reload() }

      showBrowserSetup() { this.browserSetupModalTarget.classList.add("browser-setup-modal--visible") }
      closeBrowserSetup() { this.browserSetupModalTarget.classList.remove("browser-setup-modal--visible") }

      tryAnywayLoad() { this.forceLoadModel() }

      async forceLoadModel() {
        this.updateModelStatus("loading")
        this.modelLoading = true
        if (!window.WebLLMManager) { this.updateModelStatus("error"); this.modelLoading = false; return }

        try {
          const webllmManager = window.getWebLLMManager()
          await webllmManager.loadModel(this.modelSelectTarget.value)
          this.updateModelStatus("loaded")
          window.WebLLMState.model = this.modelSelectTarget.value
          window.WebLLMState.isLoaded = true
          this.modelLoading = false
          this.notifyModelLoaded()
        } catch (error) {
          this.updateModelStatus("error")
          this.modelLoading = false
        }
      }

      notifyModelLoaded() {
        window.dispatchEvent(new CustomEvent("webLLMModelLoaded", { detail: { model: window.WebLLMState.model, isLoaded: true } }))
      }

      notifyModelUnloaded() {
        window.dispatchEvent(new CustomEvent("webLLMModelUnloaded", { detail: { model: null, isLoaded: false } }))
      }
    }
  JS

  # --- Importmap pins ---

  append_to_file "config/importmap.rb", <<~RUBY
    pin "web-llm-demo", to: "web-llm-demo.js"
  RUBY

  # --- CSS ---

  file "app/assets/stylesheets/vv_chat.css", <<~CSS
    /* WebLLM Chat */
    .web-llm-chat {
      border: 1px solid #ccc;
      border-radius: 8px;
      padding: 16px;
      background-color: #f9f9f9;
      display: flex;
      flex-direction: column;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
    .web-llm-chat__title { margin: 0; color: #333; }
    .web-llm-chat__messages {
      border: 1px solid #ddd;
      border-radius: 4px;
      padding: 12px;
      overflow-y: auto;
      background-color: white;
      margin-bottom: 16px;
    }
    .web-llm-chat__message { margin-bottom: 12px; padding: 8px 12px; border-radius: 6px; max-width: 80%; }
    .web-llm-chat__message--user { background-color: #007bff; color: white; margin-left: auto; }
    .web-llm-chat__message--assistant { background-color: #e9ecef; color: #333; }
    .web-llm-chat__message--system { background-color: #f8f9fa; color: #6c757d; font-style: italic; text-align: center; }
    .web-llm-chat__input { display: flex; gap: 8px; }
    .web-llm-chat__input-field { flex: 1; padding: 8px 12px; border: 1px solid #ddd; border-radius: 4px; font-size: 16px; }
    .web-llm-chat__send-button { padding: 8px 16px; background-color: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 16px; }
    .web-llm-chat__send-button:hover { background-color: #0056b3; }
    .web-llm-chat__send-button:disabled { background-color: #6c757d; cursor: not-allowed; }

    /* Settings Gear */
    .settings-gear-container { position: fixed; top: 20px; right: 20px; z-index: 1000; }
    .settings-gear { width: 40px; height: 40px; border: none; background: #fff; border-radius: 50%; box-shadow: 0 2px 10px rgba(0,0,0,0.1); cursor: pointer; font-size: 20px; color: #666; transition: all 0.3s ease; display: flex; align-items: center; justify-content: center; }
    .settings-gear:hover { transform: rotate(90deg); color: #007bff; }

    /* Status Panel */
    .chat-status-panel { position: fixed; top: 70px; right: 20px; width: 320px; background: #fff; border-radius: 8px; box-shadow: 0 4px 20px rgba(0,0,0,0.15); z-index: 999; transform: translateY(-10px); opacity: 0; visibility: hidden; transition: all 0.3s ease; padding: 20px; }
    .chat-status-panel--visible { transform: translateY(0); opacity: 1; visibility: visible; }
    .chat-status-panel__title { margin: 0 0 16px 0; font-size: 20px; color: #333; border-bottom: 1px solid #eee; padding-bottom: 10px; }
    .chat-status-panel__section { margin-bottom: 20px; }
    .chat-status-panel__section-title { margin: 0 0 8px 0; font-size: 14px; font-weight: 600; color: #555; text-transform: uppercase; letter-spacing: 0.5px; }
    .chat-status-panel__status { display: flex; align-items: center; gap: 8px; }
    .chat-status-panel__indicator { width: 10px; height: 10px; border-radius: 50%; background-color: #dc3545; }
    .chat-status-panel__indicator--loading { background-color: #ffc107; animation: pulse 1.5s infinite; }
    .chat-status-panel__indicator--loaded { background-color: #28a745; }
    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
    .chat-status-panel__model-select { width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; font-size: 14px; background-color: #fff; margin-bottom: 8px; }
    .chat-status-panel__model-controls { display: flex; gap: 8px; margin-top: 8px; }
    .chat-status-panel__actions { display: flex; flex-direction: column; gap: 8px; }
    .chat-status-panel__button { padding: 8px 12px; border: 1px solid #ddd; border-radius: 4px; cursor: pointer; font-size: 14px; transition: all 0.2s ease; background: #fff; }
    .chat-status-panel__button--primary { background: #007bff; color: white; border-color: #007bff; }
    .chat-status-panel__button--primary:hover { background: #0056b3; }
    .chat-status-panel__button--secondary { background: #f8f9fa; color: #333; }
    .chat-status-panel__button--secondary:hover { background: #e9ecef; }
    .chat-status-panel__button--warning { background: #ffc107; color: #212529; border-color: #ffc107; }
    .chat-status-panel__button--warning:hover { background: #e0a800; }

    /* Browser Setup Modal */
    .browser-setup-modal { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background-color: rgba(0,0,0,0.5); z-index: 10000; display: flex; align-items: center; justify-content: center; opacity: 0; visibility: hidden; transition: all 0.3s ease; }
    .browser-setup-modal--visible { opacity: 1; visibility: visible; }
    .browser-setup-modal__content { background: #fff; border-radius: 8px; max-width: 600px; width: 90%; max-height: 80vh; overflow-y: auto; }
    .browser-setup-modal__header { padding: 20px 20px 0; border-bottom: 1px solid #eee; }
    .browser-setup-modal__title { margin: 0 0 10px 0; font-size: 24px; color: #333; }
    .browser-setup-modal__close { background: none; border: none; font-size: 24px; color: #666; cursor: pointer; float: right; }
    .browser-setup-modal__body { padding: 20px; }
    .browser-setup-modal__section { margin-bottom: 24px; }
    .browser-setup-modal__flag-list { list-style: none; padding: 0; margin: 0; }
    .browser-setup-modal__flag-item { background: #f8f9fa; border-left: 3px solid #007bff; padding: 8px 12px; margin-bottom: 6px; border-radius: 0 4px 4px 0; }
    .browser-setup-modal__flag-name { font-family: monospace; font-weight: 600; color: #495057; }
    .browser-setup-modal__flag-description { color: #6c757d; font-size: 14px; margin-top: 4px; }
    .browser-setup-modal__note { background: #fff3cd; border: 1px solid #ffeaa7; border-radius: 4px; padding: 12px; margin-top: 16px; }
    .browser-setup-modal__note-title { font-weight: 600; color: #856404; margin-bottom: 8px; }
    .browser-setup-modal__note-text { color: #856404; font-size: 14px; }
  CSS

  say ""
  say "vv-rails example app generated!", :green
  say "  Chat UI:       GET /"
  say "  Plugin config:  GET /vv/config.json"
  say ""
  say "Next steps:"
  say "  1. Copy WebLLM JS bundles into public/js/ (web-llm.js, get_started.js)"
  say "  2. rails server"
  say "  3. Open http://localhost:3000 and load a model"
  say ""
end
