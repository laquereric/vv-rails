# modules/ui_example_form.rb — Beneficiary form demo UI
#
# Provides: AppController, BeneficiaryForm model, 8-field beneficiary form view,
# vv_app Stimulus controller with SSN masking, field help, pre-submit validation,
# post-submit error resolution, guided walkthrough.
#
# Depends on: base, events_form_lifecycle, events_browser_manager


@vv_applied_modules ||= []; @vv_applied_modules << "ui_example_form"

after_bundle do
  # --- Routes ---

  unless File.read("config/routes.rb").lines.any? { |l| l.strip.start_with?("root ") }
    route 'root "app#index"'
  end
  route 'post "app/validate", to: "app#validate"'
  route 'mount RailsEventStore::Browser => "/res" if Rails.env.development?'

  # --- B1: BeneficiaryForm model ---

  file "app/models/beneficiary_form.rb", <<~'RUBY'
    class BeneficiaryForm
      include ActiveModel::Model
      include ActiveModel::Validations

      RELATIONSHIPS = %w[spouse child parent sibling other].freeze

      attr_accessor :first_name, :last_name, :date_of_birth, :ssn,
                    :address, :relationship, :percentage, :contingent,
                    :current_user

      validates :first_name, presence: true, length: { minimum: 2 }
      validates :last_name, presence: true, length: { minimum: 2 }
      validates :date_of_birth, presence: true
      validates :ssn, presence: true, format: { with: /\A\d{3}-\d{2}-\d{4}\z/, message: "must be in XXX-XX-XXXX format" }
      validates :address, presence: true, length: { minimum: 10 }
      validates :relationship, presence: true, inclusion: { in: RELATIONSHIPS }
      validates :percentage, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 100 }

      validate :dob_not_in_future
      validate :not_self_as_beneficiary
      validate :minor_relationship_check

      private

      def dob_not_in_future
        return if date_of_birth.blank?
        parsed = date_of_birth.is_a?(Date) ? date_of_birth : Date.parse(date_of_birth.to_s)
        errors.add(:date_of_birth, "cannot be in the future") if parsed > Date.current
      rescue ArgumentError
        errors.add(:date_of_birth, "is not a valid date")
      end

      def not_self_as_beneficiary
        return if first_name.blank? || last_name.blank? || current_user.blank?
        full_name = "#{first_name} #{last_name}".strip
        if full_name.downcase == current_user.to_s.downcase
          errors.add(:first_name, "cannot be the same as the account holder")
          errors.add(:last_name, "cannot be the same as the account holder")
        end
      end

      def minor_relationship_check
        return if date_of_birth.blank? || relationship.blank?
        parsed = date_of_birth.is_a?(Date) ? date_of_birth : Date.parse(date_of_birth.to_s)
        age = ((Date.current - parsed).to_i / 365.25).floor
        if relationship == "spouse" && age < 18
          errors.add(:relationship, "spouse designation requires beneficiary to be 18 or older")
        end
      rescue ArgumentError
        # date parsing handled by dob_not_in_future
      end
    end
  RUBY

  # --- AppController with validate action ---

  file "app/controllers/app_controller.rb", <<~RUBY
    class AppController < ApplicationController
      def index
      end

      def validate
        form = BeneficiaryForm.new(validate_params)
        if form.valid?
          render json: { errors: {} }
        else
          render json: { errors: form.errors.messages }, status: :unprocessable_entity
        end
      end

      private

      def validate_params
        params.permit(:first_name, :last_name, :date_of_birth, :ssn,
                       :address, :relationship, :percentage, :contingent,
                       :current_user)
      end
    end
  RUBY

  # --- View: 8-field beneficiary form ---

  file "app/views/app/index.html.erb", <<~'ERB'
    <div class="app-page" data-controller="vv-app" data-vv-app-current-user-value="John Jones">
      <!-- Beneficiary Form -->
      <div class="app-form" data-vv-app-target="frame">
        <h2 class="app-form__heading">Beneficiary Designation</h2>

        <div class="app-form__row">
          <div class="app-form__field">
            <label for="first_name">First Name</label>
            <input type="text" id="first_name" name="first_name" data-field="first_name" placeholder="Legal first name" autocomplete="off">
          </div>
          <div class="app-form__field">
            <label for="last_name">Last Name</label>
            <input type="text" id="last_name" name="last_name" data-field="last_name" placeholder="Legal last name" autocomplete="off">
          </div>
        </div>

        <div class="app-form__row">
          <div class="app-form__field">
            <label for="date_of_birth">Date of Birth</label>
            <input type="date" id="date_of_birth" name="date_of_birth" data-field="date_of_birth" autocomplete="off">
          </div>
          <div class="app-form__field">
            <label for="ssn">SSN</label>
            <input type="text" id="ssn" name="ssn" data-field="ssn" placeholder="XXX-XX-XXXX" maxlength="11" autocomplete="off">
          </div>
        </div>

        <div class="app-form__field">
          <label for="address">Address</label>
          <textarea id="address" name="address" data-field="address" rows="2" placeholder="Mailing address for correspondence" autocomplete="off"></textarea>
        </div>

        <div class="app-form__row">
          <div class="app-form__field">
            <label for="relationship">Relationship</label>
            <select id="relationship" name="relationship" data-field="relationship">
              <option value="">Select...</option>
              <option value="spouse">Spouse</option>
              <option value="child">Child</option>
              <option value="parent">Parent</option>
              <option value="sibling">Sibling</option>
              <option value="other">Other</option>
            </select>
          </div>
          <div class="app-form__field">
            <label for="percentage">Percentage</label>
            <input type="number" id="percentage" name="percentage" data-field="percentage" min="1" max="100" placeholder="1-100" autocomplete="off">
          </div>
        </div>

        <div class="app-form__field app-form__field--checkbox">
          <label>
            <input type="checkbox" id="contingent" name="contingent" data-field="contingent">
            Contingent beneficiary (receives benefits only if primary is unavailable)
          </label>
        </div>

        <div class="app-form__actions">
          <button type="button" class="app-form__submit" id="form-send">Submit Designation</button>
          <button type="button" class="app-form__walkthrough-btn" id="walkthrough-btn">Show me how</button>
        </div>
        <div class="app-form__status" id="form-status"></div>
      </div>

      <!-- No-plugin notice -->
      <div class="no-plugin" data-vv-app-target="noPlugin">
        <p>Vv extension not detected.</p>
        <p class="no-plugin__hint">Install the <a href="https://github.com/laquereric/vv-plugin" target="_blank">Vv Chrome Extension</a> to enable AI chat.</p>
      </div>

      <!-- B5: Walkthrough overlay -->
      <div class="walkthrough-backdrop" id="walkthrough-backdrop" style="display:none"></div>
      <div class="walkthrough-tooltip" id="walkthrough-tooltip" style="display:none">
        <div class="walkthrough-tooltip__content" id="walkthrough-content"></div>
        <div class="walkthrough-tooltip__footer">
          <span class="walkthrough-tooltip__progress" id="walkthrough-progress"></span>
          <button class="walkthrough-tooltip__skip" id="walkthrough-skip">Skip</button>
          <button class="walkthrough-tooltip__next" id="walkthrough-next">Next</button>
        </div>
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
        this.ssnRawValue = ""
        this.detectPlugin()
        this.setupSSNMasking()

        // B5: Auto-start walkthrough if ?walkthrough=true
        if (new URLSearchParams(window.location.search).get("walkthrough") === "true") {
          this.startWalkthrough()
        }

        // B5: Walkthrough button
        const wtBtn = document.getElementById("walkthrough-btn")
        if (wtBtn) wtBtn.addEventListener("click", () => this.startWalkthrough())
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
          let value = input.type === "checkbox" ? input.checked : input.value || ""
          // SSN: send raw value, not masked display
          if (name === "ssn" && this.ssnRawValue) value = this.ssnRawValue
          fields[name] = { label, value }
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
            formTitle: "Beneficiary Designation",
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
              formTitle: "Beneficiary Designation",
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

      // --- B1: SSN Masking ---
      setupSSNMasking() {
        const ssnInput = document.getElementById("ssn")
        if (!ssnInput) return

        ssnInput.addEventListener("input", (e) => {
          let raw = e.target.value.replace(/\D/g, "").slice(0, 9)
          if (raw.length > 5) raw = raw.slice(0, 3) + "-" + raw.slice(3, 5) + "-" + raw.slice(5)
          else if (raw.length > 3) raw = raw.slice(0, 3) + "-" + raw.slice(3)
          this.ssnRawValue = raw
          e.target.value = raw
        })

        ssnInput.addEventListener("blur", () => {
          if (this.ssnRawValue && this.ssnRawValue.length === 11) {
            ssnInput.value = "***-**-" + this.ssnRawValue.slice(7)
          }
        })

        ssnInput.addEventListener("focus", () => {
          if (this.ssnRawValue) ssnInput.value = this.ssnRawValue
        })
      }

      // --- Form Submit ---
      setupFormSubmit() {
        const btn = document.getElementById("form-send")
        if (!btn) return

        // B3: Handle pre-submit validation result
        window.addEventListener("message", (event) => {
          if (event.source !== window) return
          if (event.data?.type !== "vv:form:submit:result") return

          const status = document.getElementById("form-status")
          const { ok, warnings } = event.data

          if (ok) {
            // B3: Show warnings as amber hints if present
            if (warnings && Object.keys(warnings).length > 0) {
              this.showWarnings(warnings)
              if (status) { status.textContent = "Review warnings, then resubmit"; status.style.color = "#e67e22" }
              btn.disabled = false
            } else {
              if (status) { status.textContent = "Submitting..."; status.style.color = "#667eea" }
              this.submitToApplication()
            }
          } else {
            if (status) { status.textContent = "Review needed \u2014 see chat sidebar"; status.style.color = "#e67e22" }
            btn.disabled = false
          }
        })

        // B4: Handle post-submit error suggestions
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

              // B4: Clear error on edit
              input.addEventListener("input", () => {
                fieldDiv.classList.remove("app-form__field--error")
                fieldDiv.querySelectorAll(".app-form__field-hint").forEach(el => el.remove())
              }, { once: true })
            }
          })

          const status = document.getElementById("form-status")
          if (status && summary) { status.textContent = summary; status.style.color = "#e67e22" }
        })

        btn.addEventListener("click", () => {
          const fields = this.getFormFields()
          const status = document.getElementById("form-status")

          // Client-side required check
          const required = ["first_name", "last_name", "date_of_birth", "ssn", "address", "relationship", "percentage"]
          const missing = required.filter(f => !fields[f]?.value || fields[f].value === "" || fields[f].value === false)
          if (missing.length > 0) {
            if (status) { status.textContent = "Please fill in all required fields."; status.style.color = "#dc3545" }
            return
          }

          this.clearFieldHints()
          this.clearWarnings()
          if (status) { status.textContent = "Validating with AI..."; status.style.color = "#667eea" }
          btn.disabled = true

          const currentUser = this.currentUserValue || "Unknown"
          window.postMessage({
            type: "vv:form:submit",
            data: {
              formTitle: "Beneficiary Designation",
              currentUser,
              fields
            }
          }, "*")

          setTimeout(() => { btn.disabled = false }, 15000)
        })
      }

      // B4: Submit to server-side validation
      submitToApplication() {
        const fields = this.getFormFields()
        const currentUser = this.currentUserValue || "Unknown"
        const btn = document.getElementById("form-send")
        const status = document.getElementById("form-status")

        const body = {
          first_name: fields.first_name?.value,
          last_name: fields.last_name?.value,
          date_of_birth: fields.date_of_birth?.value,
          ssn: fields.ssn?.value,
          address: fields.address?.value,
          relationship: fields.relationship?.value,
          percentage: fields.percentage?.value,
          contingent: fields.contingent?.value || false,
          current_user: currentUser
        }

        fetch("/app/validate", {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content },
          body: JSON.stringify(body)
        }).then(res => res.json()).then(data => {
          if (!data.errors || Object.keys(data.errors).length === 0) {
            if (status) { status.textContent = "Designation submitted successfully!"; status.style.color = "#28a745" }
            if (btn) btn.disabled = false
          } else {
            if (status) { status.textContent = "Resolving errors..."; status.style.color = "#e67e22" }
            // B4: Show raw errors and trigger LLM error resolution
            this.showErrors(data.errors)
            window.postMessage({
              type: "vv:event",
              event: "form:errors",
              data: { formTitle: "Beneficiary Designation", currentUser, fields, errors: data.errors }
            }, "*")
            if (btn) btn.disabled = false
          }
        }).catch(() => {
          if (status) { status.textContent = "Validation failed. Please try again."; status.style.color = "#dc3545" }
          if (btn) btn.disabled = false
        })
      }

      // B3: Show warnings as amber hints
      showWarnings(warnings) {
        Object.entries(warnings).forEach(([fieldName, warning]) => {
          const input = this.element.querySelector(`[data-field="${fieldName}"]`)
          if (!input) return
          const fieldDiv = input.closest(".app-form__field")
          if (fieldDiv) {
            fieldDiv.classList.add("app-form__field--warning")
            const warnEl = document.createElement("div")
            warnEl.className = "app-form__field-warning"
            warnEl.textContent = warning
            fieldDiv.appendChild(warnEl)
          }
        })
      }

      clearWarnings() {
        this.element.querySelectorAll(".app-form__field--warning").forEach(el => el.classList.remove("app-form__field--warning"))
        this.element.querySelectorAll(".app-form__field-warning").forEach(el => el.remove())
      }

      // B4: Show raw server errors inline
      showErrors(errors) {
        Object.entries(errors).forEach(([fieldName, messages]) => {
          const input = this.element.querySelector(`[data-field="${fieldName}"]`)
          if (!input) return
          const fieldDiv = input.closest(".app-form__field")
          if (fieldDiv) {
            fieldDiv.classList.add("app-form__field--error")
            const errEl = document.createElement("div")
            errEl.className = "app-form__field-error"
            errEl.textContent = messages.join("; ")
            fieldDiv.appendChild(errEl)
          }
        })
      }

      clearFieldHints() {
        this.element.querySelectorAll(".app-form__field--error").forEach(el => el.classList.remove("app-form__field--error"))
        this.element.querySelectorAll(".app-form__field-hint, .app-form__field-error").forEach(el => el.remove())
      }

      // --- Field Help: '?' trigger ---
      setupFieldHelp() {
        this.element.querySelectorAll("[data-field]").forEach(input => {
          if (input.type === "checkbox" || input.tagName === "SELECT") return

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
                  formTitle: "Beneficiary Designation",
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

      // --- B5: Guided Walkthrough ---
      startWalkthrough() {
        if (localStorage.getItem("vv-walkthrough-done") === "true") return

        this.walkthroughStep = 0
        this.walkthroughSteps = [
          { target: ".app-form__heading", title: "Beneficiary Designation", text: "This form designates who receives benefits. All fields are AI-assisted \u2014 type ? in any field for contextual help." },
          { target: "[data-field='first_name']", title: "Identity Fields", text: "Enter the beneficiary's legal name as it appears on government ID. The AI validates for logical consistency." },
          { target: "[data-field='ssn']", title: "SSN Masking", text: "Social Security Numbers are automatically masked after entry. The AI never sees the full SSN \u2014 only the format is validated." },
          { target: "[data-field='relationship']", title: "Relationship & Percentage", text: "Select the beneficiary's relationship to you. The AI checks for contradictions (e.g., spouse under 18)." },
          { target: "#form-send", title: "AI Pre-Validation", text: "Before the form submits, the AI reviews all fields for logical issues and warns you. After submission, validation errors get AI-enhanced fix suggestions." },
          { target: ".app-form", title: "Ready to Go!", text: "You're all set. Fill in the form and experience AI-assisted beneficiary designation. The AI observes your progress and helps in real time." }
        ]

        this.showWalkthroughStep()

        document.getElementById("walkthrough-next").addEventListener("click", () => {
          this.walkthroughStep++
          if (this.walkthroughStep >= this.walkthroughSteps.length) {
            this.endWalkthrough()
          } else {
            this.showWalkthroughStep()
          }
        })

        document.getElementById("walkthrough-skip").addEventListener("click", () => this.endWalkthrough())
      }

      showWalkthroughStep() {
        const step = this.walkthroughSteps[this.walkthroughStep]
        const target = document.querySelector(step.target)
        const backdrop = document.getElementById("walkthrough-backdrop")
        const tooltip = document.getElementById("walkthrough-tooltip")
        const content = document.getElementById("walkthrough-content")
        const progress = document.getElementById("walkthrough-progress")
        const nextBtn = document.getElementById("walkthrough-next")

        backdrop.style.display = "block"
        tooltip.style.display = "block"

        content.innerHTML = `<strong>${step.title}</strong><p>${step.text}</p>`
        progress.textContent = `${this.walkthroughStep + 1} of ${this.walkthroughSteps.length}`
        nextBtn.textContent = this.walkthroughStep === this.walkthroughSteps.length - 1 ? "Done" : "Next"

        if (target) {
          const rect = target.getBoundingClientRect()
          target.classList.add("walkthrough-spotlight")

          // Position tooltip below target
          tooltip.style.top = `${rect.bottom + window.scrollY + 12}px`
          tooltip.style.left = `${Math.max(16, rect.left)}px`
        }

        // Remove previous spotlight
        document.querySelectorAll(".walkthrough-spotlight").forEach(el => {
          if (el !== target) el.classList.remove("walkthrough-spotlight")
        })
      }

      endWalkthrough() {
        document.getElementById("walkthrough-backdrop").style.display = "none"
        document.getElementById("walkthrough-tooltip").style.display = "none"
        document.querySelectorAll(".walkthrough-spotlight").forEach(el => el.classList.remove("walkthrough-spotlight"))
        localStorage.setItem("vv-walkthrough-done", "true")
      }
    }
  JS

  # --- CSS ---

  file "app/assets/stylesheets/vv_example.css", <<~CSS
    /* Reset — inherits from DS foundation when ui_design_system is loaded */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: var(--vv-font-sans, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif); background: var(--vv-background, #f0f2f5); color: var(--pm-text, #333); min-height: 100vh; }

    /* Header */
    .vv-header { background: var(--pm-header-bg, #1a1a2e); padding: 0 24px; display: flex; align-items: center; height: 56px; gap: 16px; }
    .vv-header__logo { height: 36px; }
    .vv-header__title { color: rgba(255,255,255,0.7); font-size: 15px; flex: 1; }
    .vv-header__user { color: rgba(255,255,255,0.85); font-size: 14px; font-weight: 500; }
    .vv-header__plugin-status { font-size: 12px; padding: 4px 10px; border-radius: 12px; background: rgba(255,255,255,0.1); color: rgba(255,255,255,0.5); }
    .vv-header__plugin-status--active { background: rgba(40,167,69,0.2); color: #28a745; }
    .vv-header__plugin-status--inactive { background: rgba(220,53,69,0.2); color: #dc3545; }

    /* App Page */
    .app-page { display: flex; flex-direction: column; align-items: center; padding: 48px 24px; min-height: calc(100vh - 56px); position: relative; }

    /* Form */
    .app-form { width: 100%; max-width: 560px; background: var(--pm-surface, white); border-radius: var(--pm-radius, 12px); padding: 36px 32px; box-shadow: var(--pm-surface-shadow, 0 2px 12px rgba(0,0,0,0.08)); }
    .app-form__heading { font-size: 22px; font-weight: 600; color: #1a1a2e; margin-bottom: 28px; }
    .app-form__row { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
    .app-form__field { margin-bottom: 20px; }
    .app-form__field label { display: block; font-size: 14px; font-weight: 500; color: #555; margin-bottom: 6px; }
    .app-form__field input, .app-form__field select, .app-form__field textarea { width: 100%; padding: 12px 14px; border: 2px solid #e0e0e0; border-radius: 8px; font-size: 15px; outline: none; transition: border-color 0.2s; font-family: inherit; }
    .app-form__field input:focus, .app-form__field select:focus, .app-form__field textarea:focus { border-color: #667eea; }
    .app-form__field--checkbox { margin-bottom: 20px; }
    .app-form__field--checkbox label { display: flex; align-items: center; gap: 10px; font-size: 14px; cursor: pointer; }
    .app-form__field--checkbox input[type="checkbox"] { width: auto; padding: 0; }
    .app-form__actions { display: flex; gap: 12px; align-items: center; margin-top: 8px; }
    .app-form__submit { flex: 1; padding: 14px; background: linear-gradient(135deg, #667eea, #764ba2); color: white; border: none; border-radius: 8px; font-size: 16px; font-weight: 600; cursor: pointer; transition: opacity 0.2s; }
    .app-form__submit:hover { opacity: 0.9; }
    .app-form__submit:disabled { opacity: 0.5; cursor: not-allowed; }
    .app-form__walkthrough-btn { padding: 14px 16px; background: transparent; color: #667eea; border: 2px solid #667eea; border-radius: 8px; font-size: 14px; font-weight: 500; cursor: pointer; white-space: nowrap; }
    .app-form__walkthrough-btn:hover { background: rgba(102,126,234,0.05); }
    .app-form__status { text-align: center; margin-top: 12px; font-size: 14px; color: #28a745; min-height: 20px; }

    /* B3: Warning state (pre-submit soft warnings) */
    .app-form__field--warning input, .app-form__field--warning select, .app-form__field--warning textarea { border-color: #ffc107; background: #fffbf0; }
    .app-form__field-warning { font-size: 13px; color: #e67e22; margin-top: 4px; padding-left: 2px; }

    /* B4: Error state (post-submit errors + hints) */
    .app-form__field--error input, .app-form__field--error select, .app-form__field--error textarea { border-color: #dc3545; background: #fef5f5; }
    .app-form__field-error { font-size: 13px; color: #dc3545; margin-top: 4px; padding-left: 2px; }
    .app-form__field-hint { font-size: 13px; color: #e67e22; margin-top: 2px; padding-left: 2px; font-style: italic; }

    /* Field help (? trigger) */
    .app-form__field-help { font-size: 13px; color: #667eea; margin-top: 4px; padding-left: 2px; font-style: italic; }

    /* No Plugin Notice */
    .no-plugin { display: none; text-align: center; margin-top: 20px; color: #888; font-size: 14px; }
    .no-plugin__hint { margin-top: 6px; }
    .no-plugin__hint a { color: #007bff; }

    /* B5: Walkthrough */
    .walkthrough-backdrop { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); z-index: 1000; }
    .walkthrough-spotlight { position: relative; z-index: 1001; box-shadow: 0 0 0 4px #667eea, 0 0 0 9999px rgba(0,0,0,0.5); border-radius: 8px; }
    .walkthrough-tooltip { position: absolute; z-index: 1002; background: white; border-radius: 12px; padding: 20px; max-width: 380px; box-shadow: 0 4px 24px rgba(0,0,0,0.15); }
    .walkthrough-tooltip__content strong { display: block; font-size: 16px; margin-bottom: 8px; color: #1a1a2e; }
    .walkthrough-tooltip__content p { font-size: 14px; color: #555; line-height: 1.5; }
    .walkthrough-tooltip__footer { display: flex; align-items: center; gap: 12px; margin-top: 16px; padding-top: 12px; border-top: 1px solid #eee; }
    .walkthrough-tooltip__progress { font-size: 12px; color: #aaa; flex: 1; }
    .walkthrough-tooltip__skip { padding: 6px 14px; background: transparent; border: 1px solid #ddd; border-radius: 6px; font-size: 13px; cursor: pointer; color: #888; }
    .walkthrough-tooltip__next { padding: 6px 14px; background: #667eea; color: white; border: none; border-radius: 6px; font-size: 13px; font-weight: 600; cursor: pointer; }

    @media (max-width: 600px) {
      .app-form__row { grid-template-columns: 1fr; }
      .walkthrough-tooltip { left: 16px !important; right: 16px; max-width: none; bottom: 16px; top: auto !important; }
    }
  CSS
end
