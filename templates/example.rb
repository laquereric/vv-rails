# vv-rails example template
#
# Generates an example app that detects the Vv browser plugin.
# Without plugin: displays an empty app frame with "Your App Here".
# With plugin: tells the plugin to show its Shadow DOM chat UI and
# routes chat messages through ActionCable via the Rails EventBus.
# Persists form lifecycle events via Rails Event Store, Turns and
# form state in SQLite via the same schema as host.rb.
#
# Usage:
#   rails new myapp -m vendor/vv-rails/templates/example.rb
#

# --- Gems ---

gem "vv-rails", path: "vendor/vv-rails"
gem "vv-browser-manager", path: "vendor/vv-browser-manager"
gem "vv-memory", path: "vendor/vv-memory"
gem "rails_event_store"

# --- vv:install (inlined — creates initializer and mounts engine) ---

initializer "vv_rails.rb", <<~RUBY
  Vv::Rails.configure do |config|
    config.channel_prefix = "vv"
  end

  Rails.configuration.to_prepare do
    Rails.configuration.event_store = RailsEventStore::Client.new
  end

  # --- Helper: find or create session for this channel ---

  def self.vv_session_for(channel)
    page_id = channel.params["page_id"] || "example"
    Session.find_or_create_by!(title: "example:\#{page_id}") do |s|
      s.metadata = { page_id: page_id }
    end
  end

  def self.vv_model
    Model.find_by(api_model_id: "webllm-default") || Model.first
  end

  def self.vv_preset
    vv_model&.presets&.find_by(name: "default")
  end

  def self.vv_publish(session, event)
    Rails.configuration.event_store.publish(event, stream_name: "session:\#{session.id}")
  end

  # --- EventBus handlers ---

  Vv::Rails::EventBus.on("form:open") do |data, context|
    channel = context[:channel]
    session = vv_session_for(channel)
    form_title = data["formTitle"] || "Form"
    fields = data["fields"] || {}

    vv_publish(session, Vv::Rails::Events::FormOpened.new(data: {
      role: "system",
      content: fields.to_json,
      form_title: form_title,
      opened_at: Time.current.iso8601
    }))

    Rails.logger.info "[vv] form opened: \#{form_title} with \#{fields.keys.length} fields"
  end

  Vv::Rails::EventBus.on("form:poll") do |data, context|
    channel = context[:channel]
    session = vv_session_for(channel)
    fields = data["fields"] || {}
    form_title = data["formTitle"] || "Form"

    filled = fields.count { |_, info| info["value"].to_s.strip.present? }
    total = fields.length
    focused = data["focusedField"]

    vv_publish(session, Vv::Rails::Events::FormPolled.new(data: {
      role: "system",
      content: fields.to_json,
      form_title: form_title,
      fields_filled: filled,
      fields_total: total,
      focused_field: focused,
      polled_at: Time.current.iso8601
    }))
  end

  Vv::Rails::EventBus.on("chat:typing") do |data, context|
    channel = context[:channel]
    session = vv_session_for(channel)
    page_content = data["pageContent"] || {}
    form_fields = page_content["formFields"] || {}

    vv_publish(session, Vv::Rails::Events::FormStateChanged.new(data: {
      role: "user",
      content: form_fields.to_json
    }))

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
    channel = context[:channel]
    session = vv_session_for(channel)

    role = data["role"] || "user"
    vv_publish(session, Vv::Rails::Events::UserInputReceived.new(data: {
      role: role,
      content: data["content"].to_s
    }))

    Rails.logger.info "[vv] chat persisted: \#{data['content']&.truncate(80)}"
  end

  # --- Form submit, error resolution, and field help ---

  pending_requests = {}

  Vv::Rails::EventBus.on("form:submit") do |data, context|
    channel = context[:channel]
    session = vv_session_for(channel)
    fields = data["fields"] || {}
    current_user = data["currentUser"] || "Unknown"
    form_title = data["formTitle"] || "Form"

    vv_publish(session, Vv::Rails::Events::FormStateChanged.new(data: {
      role: "user",
      content: fields.to_json,
      form_title: form_title,
      current_user: current_user,
      event_trigger: "form:submit"
    }))

    # Check for easter egg
    epu_value = fields.dig("e_pluribus_unum", "value").to_s
    if epu_value.downcase.strip == "easter egg"
      first_name = fields.dig("first_name", "value").to_s
      last_name = fields.dig("last_name", "value").to_s

      easter_egg_html = <<~HTML
        <div class="vv-rich__header">
          <span class="vv-rich__badge"><svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 0 100 100">
            <defs>
              <linearGradient id="egg-grad" x1="0%" y1="0%" x2="100%" y2="100%">
                <stop offset="0%" style="stop-color:#f6d365"/>
                <stop offset="50%" style="stop-color:#fda085"/>
                <stop offset="100%" style="stop-color:#f6d365"/>
              </linearGradient>
              <linearGradient id="band-grad" x1="0%" y1="0%" x2="100%" y2="0%">
                <stop offset="0%" style="stop-color:#667eea"/>
                <stop offset="100%" style="stop-color:#764ba2"/>
              </linearGradient>
            </defs>
            <ellipse cx="50" cy="55" rx="32" ry="40" fill="url(#egg-grad)" stroke="#e0a030" stroke-width="2"/>
            <path d="M 18 50 Q 50 35, 82 50" fill="none" stroke="url(#band-grad)" stroke-width="5" stroke-linecap="round"/>
            <path d="M 22 60 Q 50 75, 78 60" fill="none" stroke="url(#band-grad)" stroke-width="3" stroke-linecap="round" opacity="0.6"/>
            <circle cx="38" cy="45" r="3" fill="#764ba2" opacity="0.7"/>
            <circle cx="58" cy="42" r="4" fill="#667eea" opacity="0.7"/>
            <circle cx="50" cy="58" r="2.5" fill="#f6d365" opacity="0.8"/>
            <circle cx="42" cy="65" r="2" fill="#fda085" opacity="0.6"/>
            <circle cx="62" cy="55" r="3" fill="#764ba2" opacity="0.5"/>
            <text x="50" y="12" text-anchor="middle" font-size="14">&#10024;</text>
          </svg></span>
          <span class="vv-rich__header-text">Easter Egg Found!</span>
        </div>

        <div class="vv-rich__body">
          Congratulations, <strong>\#{first_name} \#{last_name}</strong>! You discovered the hidden easter egg
          in the Beneficiary form. <em>E Pluribus Unum</em> &mdash; "Out of many, one" &mdash; is the motto on
          the Great Seal of the United States, symbolizing the union of states and people into one nation.
        </div>

        <div class="vv-rich__divider"></div>

        <img class="vv-rich__image"
             src="https://upload.wikimedia.org/wikipedia/commons/thumb/5/5b/Greater_coat_of_arms_of_the_United_States.svg/600px-Greater_coat_of_arms_of_the_United_States.svg.png"
             alt="Great Seal of the United States"
             onerror="this.style.display='none'">

        <div class="vv-rich__body" style="font-size: 13px; opacity: 0.9;">
          The phrase first appeared on the <em>Fugio cent</em> (1787), the first official U.S. coin,
          and has been featured on the Great Seal since 1782. It was the de facto national motto until
          1956, when "In God We Trust" was officially adopted.
        </div>

        <div class="vv-rich__divider"></div>

        <div class="vv-rich__links">
          <a class="vv-rich__link vv-rich__link--primary"
             href="https://en.wikipedia.org/wiki/E_pluribus_unum"
             target="_blank" rel="noopener">
            &#128214; Wikipedia
          </a>
          <a class="vv-rich__link vv-rich__link--secondary"
             href="https://www.greatseal.com/mottoes/unum.html"
             target="_blank" rel="noopener">
            &#127963;&#65039; Great Seal History
          </a>
          <a class="vv-rich__link vv-rich__link--secondary"
             href="https://github.com/laquereric/vv-plugin"
             target="_blank" rel="noopener">
            &#9889; Vv Plugin
          </a>
        </div>

        <div class="vv-rich__divider"></div>

        <div class="vv-rich__footer">
          Discovered by \#{current_user}
        </div>
      HTML

      # Persist easter egg as a Turn with immediate completion
      model = vv_model
      if model
        message_history = session.messages_from_events
        Turn.create!(
          session: session,
          model: model,
          preset: vv_preset,
          message_history: message_history,
          request: "easter_egg",
          completion: "Easter egg found by \#{first_name} \#{last_name}"
        )
      end

      channel.emit("sidebar:open", {})
      channel.emit("sidebar:message", { html: easter_egg_html })
      channel.emit("form:submit:result", { ok: true, answer: "egg", explanation: "" })
      next
    end

    # Normal validation: build LLM prompt and request
    field_summary = (fields || {}).map do |key, info|
      label = info["label"] || key
      value = info["value"].to_s
      "  - \#{label}: \\"\#{value}\\""
    end.join("\\n")

    request_id = SecureRandom.hex(8)
    messages = [
      {
        "role" => "system",
        "content" => "You are a form validation assistant. The current logged-in user is \\"\#{current_user}\\". A \\"\#{form_title}\\" form has been filled out. A beneficiary is a person designated to receive benefits — typically someone OTHER than the account holder/current user.\\n\\nRespond ONLY with valid JSON: {\\"answer\\":\\"yes\\",\\"explanation\\":\\"...\\"} or {\\"answer\\":\\"no\\",\\"explanation\\":\\"...\\"}. The explanation should be 1-2 sentences. If the answer is \\"no\\", explain clearly what seems wrong (e.g. if the user designated themselves as their own beneficiary, explain what a beneficiary is and why they should designate someone else)."
      },
      {
        "role" => "user",
        "content" => "Current User: \#{current_user}\\nForm: \#{form_title}\\nFields:\\n\#{field_summary}\\n\\nDoes this look right?"
      }
    ]

    # Create Turn (pending completion — will be filled on llm:response)
    model = vv_model
    message_history = session.messages_from_events
    turn = if model
      Turn.create!(
        session: session,
        model: model,
        preset: vv_preset,
        message_history: message_history,
        request: messages.to_json
      )
    end

    pending_requests[request_id] = { channel: channel, data: data, session: session, turn: turn, purpose: "validation" }
    channel.emit("llm:request", {
      requestId: request_id,
      messages: messages,
      options: { max_tokens: 256, temperature: 0.3 }
    })
  end

  # --- Field help: user types '?' in a field ---

  Vv::Rails::EventBus.on("field:help") do |data, context|
    channel = context[:channel]
    session = vv_session_for(channel)
    field_name = data["fieldName"]
    field_label = data["fieldLabel"] || field_name
    form_title = data["formTitle"] || "Form"
    fields = data["fields"] || {}

    vv_publish(session, Vv::Rails::Events::FieldHelpRequested.new(data: {
      role: "system",
      content: field_name,
      field_label: field_label,
      form_title: form_title,
      fields: fields
    }))

    # Build help prompt
    field_summary = fields.map { |k, info| "  - \#{info['label'] || k}: \\"\#{info['value']}\\"" }.join("\\n")
    request_id = SecureRandom.hex(8)
    messages = [
      {
        "role" => "system",
        "content" => "You are a form field assistant for a \\"\#{form_title}\\" form. The user pressed '?' on the field \\"\#{field_label}\\". Explain what this field is for and what to enter. Be concise (1-3 sentences). Respond ONLY with valid JSON: {\\"help\\": \\"your explanation\\"}"
      },
      {
        "role" => "user",
        "content" => "Field: \#{field_label}\\nAll fields:\\n\#{field_summary}\\nWhat should I enter here?"
      }
    ]

    model = vv_model
    if model
      message_history = session.messages_from_events
      turn = Turn.create!(
        session: session,
        model: model,
        preset: vv_preset,
        message_history: message_history,
        request: messages.to_json
      )
      pending_requests[request_id] = { channel: channel, data: data, session: session, turn: turn, purpose: "field_help", field_name: field_name }
      channel.emit("llm:request", {
        requestId: request_id,
        messages: messages,
        options: { max_tokens: 256, temperature: 0.3 }
      })
    end
  end

  # --- Post-submit error resolution: application validation errors → LLM help ---

  Vv::Rails::EventBus.on("form:errors") do |data, context|
    channel = context[:channel]
    session = vv_session_for(channel)
    errors = data["errors"] || {}
    fields = data["fields"] || {}
    form_title = data["formTitle"] || "Form"
    current_user = data["currentUser"] || "Unknown"

    vv_publish(session, Vv::Rails::Events::FormErrorOccurred.new(data: {
      role: "system",
      content: errors.to_json,
      form_title: form_title,
      fields: fields
    }))

    # Build error summary for LLM
    error_summary = errors.map do |field_name, messages_list|
      label = fields.dig(field_name, "label") || field_name
      "  - \#{label} (\#{field_name}): \#{Array(messages_list).join(', ')}"
    end.join("\\n")

    field_summary = fields.map do |key, info|
      label = info["label"] || key
      value = info["value"].to_s
      "  - \#{label} (\#{key}): \\"\#{value}\\""
    end.join("\\n")

    request_id = SecureRandom.hex(8)
    messages = [
      {
        "role" => "system",
        "content" => "You are a form correction assistant for a \\"\#{form_title}\\" form. The application returned validation errors after submission. The current user is \\"\#{current_user}\\".\\n\\nHelp the user understand each error and what to fix. Respond ONLY with valid JSON: {\\"suggestions\\": {\\"field_name\\": \\"plain-language explanation of what to fix\\", ...}, \\"summary\\": \\"one sentence overall summary\\"}\\n\\nOnly include fields that have errors. Field names must match the keys provided."
      },
      {
        "role" => "user",
        "content" => "Validation errors:\\n\#{error_summary}\\n\\nCurrent field values:\\n\#{field_summary}\\n\\nHelp me fix these."
      }
    ]

    model = vv_model
    if model
      message_history = session.messages_from_events
      turn = Turn.create!(
        session: session,
        model: model,
        preset: vv_preset,
        message_history: message_history,
        request: messages.to_json
      )
      pending_requests[request_id] = { channel: channel, data: data, session: session, turn: turn, purpose: "error_resolution" }
      channel.emit("llm:request", {
        requestId: request_id,
        messages: messages,
        options: { max_tokens: 512, temperature: 0.3 }
      })
    end
  end

  # --- LLM response: branches on purpose (validation, error_resolution, field_help) ---

  Vv::Rails::EventBus.on("llm:response") do |data, context|
    request_id = data["requestId"]
    pending = pending_requests.delete(request_id)
    next unless pending

    channel = pending[:channel]
    session = pending[:session]
    turn = pending[:turn]
    raw = data["response"].to_s
    purpose = pending[:purpose] || "validation"

    # Complete the Turn with the LLM response
    if turn
      turn.update!(completion: raw)
    end

    # Persist assistant response as an event
    if session
      vv_publish(session, Vv::Rails::Events::AssistantResponded.new(data: {
        role: "assistant",
        content: raw,
        request_id: request_id,
        purpose: purpose
      }))
    end

    # Parse JSON from response (may be wrapped in markdown code block)
    parsed = begin
      json_match = raw.match(/\\{[\\s\\S]*\\}/)
      json_match ? JSON.parse(json_match[0]) : {}
    rescue JSON::ParserError
      {}
    end

    case purpose
    when "field_help"
      # Field help: deliver explanation to client
      help_text = parsed["help"] || raw
      channel.emit("field:help:response", { fieldName: pending[:field_name], help: help_text })

    when "error_resolution"
      # Post-submit: deliver LLM-enhanced error explanations to client
      suggestions = parsed["suggestions"] || {}
      summary = parsed["summary"] || "Please review the flagged fields."
      channel.emit("form:error:suggestions", { suggestions: suggestions, summary: summary, turn_id: turn&.id })

    else
      # Pre-submit validation: check pass/fail
      ok = (parsed["answer"] || "yes").to_s.downcase.start_with?("y")
      explanation = (parsed["explanation"] || raw).to_s

      if ok
        channel.emit("form:submit:result", { ok: true, answer: parsed["answer"], explanation: explanation })
      else
        channel.emit("sidebar:open", {})
        channel.emit("sidebar:message", { content: explanation, label: "Form Review" })
        channel.emit("form:submit:result", { ok: false, answer: parsed["answer"], explanation: explanation })
      end
    end
  end
RUBY

after_bundle do
  # --- Vv logo ---
  logo_src = File.join(File.dirname(__FILE__), "vv-logo.png")
  copy_file logo_src, "public/vv-logo.png" if File.exist?(logo_src)

  # --- Migrations (same schema as host.rb) ---

  generate "migration", "CreateSessions title:string metadata:json"
  generate "migration", "CreateProviders name:string api_base:string api_key_ciphertext:string priority:integer active:boolean requires_api_key:boolean"
  generate "migration", "CreateModels provider:references name:string api_model_id:string context_window:integer capabilities:json active:boolean"
  generate "migration", "CreatePresets model:references name:string temperature:float max_tokens:integer system_prompt:text top_p:float parameters:json active:boolean"
  generate "migration", "CreateTurns session:references model:references message_history:json request:text completion:text input_tokens:integer output_tokens:integer duration_ms:integer"
  # Add preset as a nullable reference (preset is optional on Turn)
  turns_migration = Dir.glob("db/migrate/*_create_turns.rb").first
  inject_into_file turns_migration, after: "t.references :model, null: false, foreign_key: true\n" do
    "      t.references :preset, null: true, foreign_key: true\n"
  end

  generate "rails_event_store_active_record:migration"

  # --- Models ---

  file "app/models/session.rb", <<~RUBY
    class Session < ApplicationRecord
      has_many :turns, -> { order(:created_at) }, dependent: :destroy

      validates :title, presence: true

      def events
        Rails.configuration.event_store.read.stream("session:\#{id}").to_a
      end

      def messages_from_events
        events.map { |e| Vv::Rails::Events.to_message_hash(e) }
      end
    end
  RUBY

  file "app/models/provider.rb", <<~RUBY
    class Provider < ApplicationRecord
      has_many :models, dependent: :destroy

      validates :name, presence: true, uniqueness: true
      validates :api_base, presence: true

      scope :active, -> { where(active: true) }
      scope :by_priority, -> { order(priority: :asc) }
    end
  RUBY

  file "app/models/model.rb", <<~RUBY
    class Model < ApplicationRecord
      belongs_to :provider
      has_many :presets, dependent: :destroy
      has_many :turns

      validates :name, presence: true
      validates :api_model_id, presence: true

      scope :active, -> { where(active: true) }
    end
  RUBY

  file "app/models/preset.rb", <<~RUBY
    class Preset < ApplicationRecord
      belongs_to :model

      validates :name, presence: true

      scope :active, -> { where(active: true) }

      def to_inference_params
        params = {}
        params[:temperature] = temperature if temperature
        params[:max_tokens] = max_tokens if max_tokens
        params[:top_p] = top_p if top_p
        params.merge((parameters || {}).symbolize_keys)
      end
    end
  RUBY

  file "app/models/turn.rb", <<~RUBY
    class Turn < ApplicationRecord
      belongs_to :session
      belongs_to :model
      belongs_to :preset, optional: true

      validates :message_history, presence: true
      validates :request, presence: true

      def token_count
        (input_tokens || 0) + (output_tokens || 0)
      end
    end
  RUBY

  # --- Seeds: WebLLM provider (client-side, no API key) ---

  append_to_file "db/seeds.rb", <<~RUBY

    webllm = Provider.find_or_create_by!(name: "WebLLM") do |p|
      p.api_base = "client://webgpu"
      p.api_key_ciphertext = nil
      p.priority = 1
      p.active = true
      p.requires_api_key = false
    end

    model = webllm.models.find_or_create_by!(api_model_id: "webllm-default") do |m|
      m.name = "WebLLM (Browser)"
      m.context_window = 4096
      m.capabilities = { "streaming" => true }
      m.active = true
    end

    model.presets.find_or_create_by!(name: "default") do |p|
      p.temperature = 0.3
      p.max_tokens = 256
      p.system_prompt = "You are a helpful form validation assistant."
      p.active = true
    end
  RUBY

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

        // Remember extension ID for disabled-vs-missing detection
        const extId = document.documentElement.getAttribute("data-vv-extension-id")
        if (extId) localStorage.setItem("vv-extension-id", extId)

        const status = document.getElementById("plugin-status")
        if (status) {
          status.textContent = "Vv Active"
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
        // Poll every 5 seconds
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

        // Check if extension is installed but disabled by probing a
        // web-accessible resource. If installed, the content script
        // would have set data-vv-extension-id; without it, we must
        // check all known extension IDs — but a simpler heuristic:
        // the attribute is absent when disabled, so we probe the
        // Chrome Web Store / known install path.
        // Since we can't know the ID without the content script,
        // we show "No Vv Extension" by default and upgrade to
        // "Vv Extension Disabled" if the user previously had it
        // (stored in localStorage).
        const knownId = localStorage.getItem("vv-extension-id")
        if (knownId) {
          // Extension was previously active — try probing its resource
          const probeUrl = `chrome-extension://${knownId}/vv-probe.txt`
          fetch(probeUrl, { mode: "no-cors" }).then(() => {
            // Resource loaded — extension is installed but disabled
            if (notice) notice.querySelector("p").textContent = "Vv extension is disabled."
            if (status) { status.textContent = "Vv Disabled"; status.classList.add("vv-header__plugin-status--inactive") }
          }).catch(() => {
            // Extension not installed (removed)
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

        // Pre-submit LLM validation result
        window.addEventListener("message", (event) => {
          if (event.source !== window) return
          if (event.data?.type !== "vv:form:submit:result") return

          const status = document.getElementById("form-status")
          const { ok, answer } = event.data

          if (answer === "egg") {
            if (status) { status.textContent = "\u{1F95A} You found it!"; status.style.color = "#764ba2" }
            btn.disabled = false
          } else if (ok) {
            // Pre-submit LLM approved — now submit to application logic
            if (status) { status.textContent = "Submitting..."; status.style.color = "#667eea" }
            this.submitToApplication()
          } else {
            if (status) { status.textContent = "Review needed \u2014 see chat sidebar"; status.style.color = "#e67e22" }
            btn.disabled = false
          }
        })

        // Post-submit: LLM-enhanced error explanations from application validation errors
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

          // Re-enable after timeout in case no response
          setTimeout(() => { btn.disabled = false }, 15000)
        })
      }

      // Application logic: submit form data and handle validation errors
      // In production, this would POST to a Rails controller.
      // When the controller returns errors, send them to the LLM for explanation.
      submitToApplication() {
        const fields = this.getFormFields()
        const currentUser = this.currentUserValue || "Unknown"
        const btn = document.getElementById("form-send")
        const status = document.getElementById("form-status")

        // Simulated application validation (replace with real POST in production)
        // Example: POST /beneficiaries, controller returns { errors: { first_name: ["can't match account holder"] } }
        const errors = this.simulateAppValidation(fields, currentUser)

        if (Object.keys(errors).length === 0) {
          // No errors — application accepted the submission
          if (status) { status.textContent = "Submitted!"; status.style.color = "#28a745" }
          if (btn) btn.disabled = false
        } else {
          // Application returned field errors — send to LLM for explanation
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

      // Simulated application validation — returns { field_name: ["error message", ...] }
      // In production, this comes from your Rails controller's model.errors
      simulateAppValidation(fields, currentUser) {
        const errors = {}
        const firstName = (fields.first_name?.value || "").trim()
        const lastName = (fields.last_name?.value || "").trim()
        const fullName = `${firstName} ${lastName}`

        // Business rule: beneficiary cannot be the account holder
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

              // Show loading hint
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

        // Listen for help responses
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

  say ""
  say "vv-rails example app generated!", :green
  say "  App:           GET /"
  say "  Plugin config: GET /vv/config.json"
  say "  Event browser: /res (development)"
  say ""
  say "Next steps:"
  say "  1. rails db:create db:migrate db:seed"
  say "  2. Install the Vv Chrome Extension"
  say "  3. rails server"
  say "  4. Open http://localhost:3000"
  say "     - Without plugin: shows 'Your App Here' frame"
  say "     - With plugin: chat input appears, sidebar opens on send"
  say ""
end
