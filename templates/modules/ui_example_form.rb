# modules/ui_example_form.rb — Beneficiary form demo UI
#
# Provides: AppController, beneficiary form view, vv_app Stimulus controller,
# example CSS, layout with plugin status.
#
# Depends on: base, events_form_lifecycle, events_browser_manager

after_bundle do
  # --- Routes ---

  route 'root "app#index"'
  route 'mount RailsEventStore::Browser => "/res" if Rails.env.development?'

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
        <p>Vv extension not detected.</p>
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
          <span class="vv-header__user" id="current-user">User: John Jones</span>
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
        this.pollTimer = null
        this.detectPlugin()
      }

      disconnect() {
        if (this.pollTimer) {
          clearInterval(this.pollTimer)
          this.pollTimer = null
        }
      }

      // --- Plugin Detection ---
      detectPlugin() {
        if (document.documentElement.getAttribute("data-vv-plugin") === "true") {
          this.onPluginFound()
          return
        }

        const handler = (event) => {
          if (event.data?.type === "vv:pong") {
            window.removeEventListener("message", handler)
            this.onPluginFound()
          }
        }
        window.addEventListener("message", handler)
        window.postMessage({ type: "vv:ping" }, "*")

        setTimeout(() => {
          window.removeEventListener("message", handler)
          if (!this.pluginDetected) this.onNoPlugin()
        }, 500)
      }

      onPluginFound() {
        this.pluginDetected = true
        this.noPluginTarget.style.display = "none"

        const extId = document.documentElement.getAttribute("data-vv-extension-id")
        if (extId) localStorage.setItem("vv-extension-id", extId)

        const status = document.getElementById("plugin-status")
        if (status) {
          status.textContent = "Vv Active"
          status.classList.add("vv-header__plugin-status--active")
        }

        window.postMessage({
          type: "vv:rails:connect",
          url: "/cable",
          channel: "VvChannel",
          pageId: "example"
        }, "*")

        window.postMessage({ type: "vv:chatbox:show" }, "*")

        this.setupFormSubmit()
        this.setupFieldHelp()
        this.emitFormOpen()
        this.startFormPolling()
      }

      // --- Form Lifecycle: open + polling ---

      getFormFields() {
        const fields = {}
        this.element.querySelectorAll("[data-field]").forEach(input => {
          const name = input.getAttribute("data-field")
          const label = this.element.querySelector(`label[for="${input.id}"]`)?.textContent || name
          fields[name] = { label, value: input.value || "" }
        })
        return fields
      }

      getFocusedField() {
        const active = document.activeElement
        if (active?.hasAttribute("data-field")) {
          return active.getAttribute("data-field")
        }
        return null
      }

      emitFormOpen() {
        window.postMessage({
          type: "vv:event",
          event: "form:open",
          data: {
            formTitle: "Beneficiary",
            fields: this.getFormFields()
          }
        }, "*")
      }

      startFormPolling() {
        this.pollTimer = setInterval(() => {
          window.postMessage({
            type: "vv:event",
            event: "form:poll",
            data: {
              formTitle: "Beneficiary",
              fields: this.getFormFields(),
              focusedField: this.getFocusedField()
            }
          }, "*")
        }, 5000)
      }

      onNoPlugin() {
        this.noPluginTarget.style.display = "block"
        const notice = this.noPluginTarget
        const status = document.getElementById("plugin-status")

        const knownId = localStorage.getItem("vv-extension-id")
        if (knownId) {
          const probeUrl = `chrome-extension://${knownId}/vv-probe.txt`
          fetch(probeUrl, { mode: "no-cors" }).then(() => {
            if (notice) notice.querySelector("p").textContent = "Vv extension is disabled."
            if (status) { status.textContent = "Vv Disabled"; status.classList.add("vv-header__plugin-status--inactive") }
          }).catch(() => {
            localStorage.removeItem("vv-extension-id")
            if (notice) notice.querySelector("p").textContent = "Vv extension not detected."
            if (status) { status.textContent = "No Vv Extension"; status.classList.add("vv-header__plugin-status--inactive") }
          })
        } else {
          if (notice) notice.querySelector("p").textContent = "Vv extension not detected."
          if (status) { status.textContent = "No Vv Extension"; status.classList.add("vv-header__plugin-status--inactive") }
        }
      }

      // --- Form Submit ---
      setupFormSubmit() {
        const btn = document.getElementById("form-send")
        if (!btn) return

        window.addEventListener("message", (event) => {
          if (event.source !== window) return
          if (event.data?.type !== "vv:form:submit:result") return

          const status = document.getElementById("form-status")
          const { ok, answer } = event.data

          if (answer === "egg") {
            if (status) { status.textContent = "\u{1F95A} You found it!"; status.style.color = "#764ba2" }
            btn.disabled = false
          } else if (ok) {
            if (status) { status.textContent = "Submitting..."; status.style.color = "#667eea" }
            this.submitToApplication()
          } else {
            if (status) { status.textContent = "Review needed \u2014 see chat sidebar"; status.style.color = "#e67e22" }
            btn.disabled = false
          }
        })

        window.addEventListener("message", (event) => {
          if (event.source !== window) return
          if (event.data?.type !== "vv:form:error:suggestions") return

          const { suggestions, summary } = event.data
          if (!suggestions) return

          this.clearFieldHints()
          Object.entries(suggestions).forEach(([fieldName, hint]) => {
            const input = this.element.querySelector(`[data-field="${fieldName}"]`)
            if (!input) return
            const fieldDiv = input.closest(".app-form__field")
            if (fieldDiv) {
              fieldDiv.classList.add("app-form__field--error")
              const hintEl = document.createElement("div")
              hintEl.className = "app-form__field-hint"
              hintEl.textContent = hint
              fieldDiv.appendChild(hintEl)
            }
          })

          const status = document.getElementById("form-status")
          if (status && summary) { status.textContent = summary; status.style.color = "#e67e22" }
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

          this.clearFieldHints()
          if (status) { status.textContent = "Validating..."; status.style.color = "#667eea" }
          btn.disabled = true

          const currentUser = this.currentUserValue || "Unknown"
          window.postMessage({
            type: "vv:form:submit",
            data: {
              formTitle: "Beneficiary",
              currentUser,
              fields: {
                first_name: { label: "First Name", value: first },
                last_name: { label: "Last Name", value: last },
                e_pluribus_unum: { label: "E Pluribus Unum", value: epu }
              }
            }
          }, "*")

          setTimeout(() => { btn.disabled = false }, 15000)
        })
      }

      submitToApplication() {
        const fields = this.getFormFields()
        const currentUser = this.currentUserValue || "Unknown"
        const btn = document.getElementById("form-send")
        const status = document.getElementById("form-status")

        const errors = this.simulateAppValidation(fields, currentUser)

        if (Object.keys(errors).length === 0) {
          if (status) { status.textContent = "Submitted!"; status.style.color = "#28a745" }
          if (btn) btn.disabled = false
        } else {
          if (status) { status.textContent = "Resolving errors..."; status.style.color = "#e67e22" }
          window.postMessage({
            type: "vv:event",
            event: "form:errors",
            data: {
              formTitle: "Beneficiary",
              currentUser,
              fields,
              errors
            }
          }, "*")
          if (btn) btn.disabled = false
        }
      }

      simulateAppValidation(fields, currentUser) {
        const errors = {}
        const firstName = (fields.first_name?.value || "").trim()
        const lastName = (fields.last_name?.value || "").trim()
        const fullName = `${firstName} ${lastName}`

        if (fullName.toLowerCase() === currentUser.toLowerCase()) {
          errors.first_name = ["cannot be the same as the account holder"]
          errors.last_name = ["cannot be the same as the account holder"]
        }

        return errors
      }

      clearFieldHints() {
        this.element.querySelectorAll(".app-form__field--error").forEach(el => el.classList.remove("app-form__field--error"))
        this.element.querySelectorAll(".app-form__field-hint").forEach(el => el.remove())
      }

      // --- Field Help: '?' trigger ---
      setupFieldHelp() {
        this.element.querySelectorAll("[data-field]").forEach(input => {
          input.addEventListener("input", (e) => {
            if (e.target.value === "?") {
              e.target.value = ""
              const fieldName = e.target.getAttribute("data-field")
              const label = this.element.querySelector(`label[for="${e.target.id}"]`)?.textContent || fieldName

              window.postMessage({
                type: "vv:event",
                event: "field:help",
                data: {
                  fieldName: fieldName,
                  fieldLabel: label,
                  formTitle: "Beneficiary",
                  fields: this.getFormFields()
                }
              }, "*")

              const fieldDiv = e.target.closest(".app-form__field")
              if (fieldDiv) {
                this.clearFieldHelp(fieldDiv)
                const hint = document.createElement("div")
                hint.className = "app-form__field-help"
                hint.textContent = "Loading..."
                fieldDiv.appendChild(hint)
              }
            }
          })
        })

        window.addEventListener("message", (event) => {
          if (event.source !== window) return
          if (event.data?.type !== "vv:field:help:response") return

          const { fieldName, help } = event.data
          if (!fieldName || !help) return

          const input = this.element.querySelector(`[data-field="${fieldName}"]`)
          if (!input) return

          const fieldDiv = input.closest(".app-form__field")
          if (fieldDiv) {
            this.clearFieldHelp(fieldDiv)
            const hint = document.createElement("div")
            hint.className = "app-form__field-help"
            hint.textContent = help
            fieldDiv.appendChild(hint)
          }
        })
      }

      clearFieldHelp(fieldDiv) {
        fieldDiv.querySelectorAll(".app-form__field-help").forEach(el => el.remove())
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

    /* Field error state (post-submit suggestions) */
    .app-form__field--error input { border-color: #e67e22; background: #fef9f3; }
    .app-form__field-hint { font-size: 13px; color: #e67e22; margin-top: 4px; padding-left: 2px; }

    /* Field help (? trigger) */
    .app-form__field-help { font-size: 13px; color: #667eea; margin-top: 4px; padding-left: 2px; font-style: italic; }

    /* No Plugin Notice */
    .no-plugin { display: none; text-align: center; margin-top: 20px; color: #888; font-size: 14px; }
    .no-plugin__hint { margin-top: 6px; }
    .no-plugin__hint a { color: #007bff; }
  CSS
end
