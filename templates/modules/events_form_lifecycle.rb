# modules/events_form_lifecycle.rb — Form lifecycle EventBus handlers
#
# Provides: form:open, form:poll, chat:typing, chat:context, chat,
# form:submit (with easter egg), field:help, form:errors, llm:response
#
# Depends on: base, schema_llm, schema_session, schema_res

after_bundle do
  # Append helpers and handlers to the vv_rails initializer
  append_to_file "config/initializers/vv_rails.rb", <<~'RUBY'

    # --- Helper: find or create session for this channel ---

    def self.vv_session_for(channel)
      page_id = channel.params["page_id"] || "example"
      Session.find_or_create_by!(title: "example:#{page_id}") do |s|
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
      Rails.configuration.event_store.publish(event, stream_name: "session:#{session.id}")
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

      if Vv::BrowserManager.model_registry.available.any?
        model = Vv::BrowserManager.model_registry.available.first
        Vv::BrowserManager::PrechargeClient.precharge(
          model_id: model.model_id,
          category: model.category,
          context: [
            { role: "system", content: "You are a form assistant helping users fill out '#{form_title}'." },
            { role: "user", content: fields.to_json }
          ]
        )
      end

      Rails.logger.info "[vv] form opened: #{form_title} with #{fields.keys.length} fields"
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

      field_summary = form_fields.map do |name, info|
        label = info["label"] || name
        value = info["value"].to_s
        status = value.strip.empty? ? "EMPTY" : "filled in with: #{value}"
        "  - #{label}: #{status}"
      end.join("\n")

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

      Rails.logger.info "[vv] chat persisted: #{data['content']&.truncate(80)}"
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
            Congratulations, <strong>#{first_name} #{last_name}</strong>! You discovered the hidden easter egg
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
            Discovered by #{current_user}
          </div>
        HTML

        model = vv_model
        if model
          message_history = session.messages_from_events
          Turn.create!(
            session: session,
            model: model,
            preset: vv_preset,
            message_history: message_history,
            request: "easter_egg",
            completion: "Easter egg found by #{first_name} #{last_name}"
          )
        end

        channel.emit("sidebar:open", {})
        channel.emit("sidebar:message", { html: easter_egg_html })
        channel.emit("form:submit:result", { ok: true, answer: "egg", explanation: "" })
        next
      end

      # Normal validation
      field_summary = (fields || {}).map do |key, info|
        label = info["label"] || key
        value = info["value"].to_s
        "  - #{label}: \"#{value}\""
      end.join("\n")

      request_id = SecureRandom.hex(8)
      messages = [
        {
          "role" => "system",
          "content" => "You are a form validation assistant. The current logged-in user is \"#{current_user}\". A \"#{form_title}\" form has been filled out. A beneficiary is a person designated to receive benefits — typically someone OTHER than the account holder/current user.\n\nRespond ONLY with valid JSON: {\"answer\":\"yes\",\"explanation\":\"...\"} or {\"answer\":\"no\",\"explanation\":\"...\"}. The explanation should be 1-2 sentences. If the answer is \"no\", explain clearly what seems wrong (e.g. if the user designated themselves as their own beneficiary, explain what a beneficiary is and why they should designate someone else)."
        },
        {
          "role" => "user",
          "content" => "Current User: #{current_user}\nForm: #{form_title}\nFields:\n#{field_summary}\n\nDoes this look right?"
        }
      ]

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

      field_summary = fields.map { |k, info| "  - #{info['label'] || k}: \"#{info['value']}\"" }.join("\n")
      request_id = SecureRandom.hex(8)
      messages = [
        {
          "role" => "system",
          "content" => "You are a form field assistant for a \"#{form_title}\" form. The user pressed '?' on the field \"#{field_label}\". Explain what this field is for and what to enter. Be concise (1-3 sentences). Respond ONLY with valid JSON: {\"help\": \"your explanation\"}"
        },
        {
          "role" => "user",
          "content" => "Field: #{field_label}\nAll fields:\n#{field_summary}\nWhat should I enter here?"
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

      error_summary = errors.map do |field_name, messages_list|
        label = fields.dig(field_name, "label") || field_name
        "  - #{label} (#{field_name}): #{Array(messages_list).join(', ')}"
      end.join("\n")

      field_summary = fields.map do |key, info|
        label = info["label"] || key
        value = info["value"].to_s
        "  - #{label} (#{key}): \"#{value}\""
      end.join("\n")

      request_id = SecureRandom.hex(8)
      messages = [
        {
          "role" => "system",
          "content" => "You are a form correction assistant for a \"#{form_title}\" form. The application returned validation errors after submission. The current user is \"#{current_user}\".\n\nHelp the user understand each error and what to fix. Respond ONLY with valid JSON: {\"suggestions\": {\"field_name\": \"plain-language explanation of what to fix\", ...}, \"summary\": \"one sentence overall summary\"}\n\nOnly include fields that have errors. Field names must match the keys provided."
        },
        {
          "role" => "user",
          "content" => "Validation errors:\n#{error_summary}\n\nCurrent field values:\n#{field_summary}\n\nHelp me fix these."
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

    Vv::Rails::EventBus.on("llm:response") do |data, context|
      request_id = data["requestId"]
      pending = pending_requests.delete(request_id)
      next unless pending

      channel = pending[:channel]
      session = pending[:session]
      turn = pending[:turn]
      raw = data["response"].to_s
      purpose = pending[:purpose] || "validation"

      if turn
        turn.update!(completion: raw)
      end

      if session
        vv_publish(session, Vv::Rails::Events::AssistantResponded.new(data: {
          role: "assistant",
          content: raw,
          request_id: request_id,
          purpose: purpose
        }))
      end

      parsed = begin
        json_match = raw.match(/\{[\s\S]*\}/)
        json_match ? JSON.parse(json_match[0]) : {}
      rescue JSON::ParserError
        {}
      end

      case purpose
      when "field_help"
        help_text = parsed["help"] || raw
        channel.emit("field:help:response", { fieldName: pending[:field_name], help: help_text })

      when "error_resolution"
        suggestions = parsed["suggestions"] || {}
        summary = parsed["summary"] || "Please review the flagged fields."
        channel.emit("form:error:suggestions", { suggestions: suggestions, summary: summary, turn_id: turn&.id })

      else
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
end
