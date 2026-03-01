# modules/events_form_lifecycle.rb — Form lifecycle EventBus handlers
#
# Provides: form:open, form:poll, chat:typing, chat:context, chat,
# form:submit (with easter egg), field:help, form:errors, llm:response
#
# Depends on: base, schema_llm, schema_session, schema_res


@vv_applied_modules ||= []; @vv_applied_modules << "events_form_lifecycle"

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
        "description" => "Insurance beneficiary designation form. The current user (account holder: John Jones) is designating a person to receive benefits. Fields: First Name, Last Name, Date of Birth, SSN (Social Security Number, masked after entry), Address (mailing address for correspondence), Relationship (spouse/child/parent/sibling/other), Percentage (benefit allocation 1-100%), Contingent (checkbox: receives benefits only if primary beneficiary is unavailable). The beneficiary must be someone OTHER than the account holder. Spouse designation requires age 18+.",
        "currentUser" => "John Jones",
        "formTitle" => "Beneficiary Designation",
        "formFields" => form_fields,
        "formSummary" => field_summary,
        "instructions" => "When the user asks about a field, explain why it is needed in the context of an insurance beneficiary designation. Reference legal, regulatory, or practical reasons. If a required field is empty, mention that it still needs to be filled in. Be helpful and concise."
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
          "content" => "You are a form validation assistant for an insurance beneficiary designation form. The current logged-in user (account holder) is \"#{current_user}\". A beneficiary is a person designated to receive benefits — someone OTHER than the account holder.\n\nValidation rules:\n1. The beneficiary name must not match the account holder name.\n2. SSN must be in XXX-XX-XXXX format (9 digits).\n3. Date of birth cannot be in the future.\n4. If relationship is \"spouse\", the beneficiary must be 18 or older.\n5. Percentage must be between 1 and 100.\n6. Address should look like a real mailing address.\n\nSoft warnings (not blocking):\n- Percentage under 100 for a single beneficiary (they may intend multiple beneficiaries).\n- A minor child (under 18) may need a custodial arrangement.\n- Contingent beneficiary with 100% allocation is unusual.\n\nRespond ONLY with valid JSON:\n- If everything looks correct: {\"answer\":\"yes\",\"explanation\":\"...\",\"warnings\":{}}\n- If there are soft warnings but no blocking issues: {\"answer\":\"yes\",\"explanation\":\"...\",\"warnings\":{\"field_name\":\"warning text\",...}}\n- If there are blocking issues: {\"answer\":\"no\",\"explanation\":\"what is wrong\"}\n\nThe explanation should be 1-2 sentences. Field names in warnings must be: first_name, last_name, date_of_birth, ssn, address, relationship, percentage, contingent."
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

      # B2: Domain-specific field help prompts
      field_help_supplements = {
        "first_name" => "This is the beneficiary's legal first name as it appears on government-issued ID. Nicknames are not accepted. Hyphenated names should include the full hyphenated form.",
        "last_name" => "This is the beneficiary's legal surname. For married beneficiaries, use their current legal name. Hyphenated surnames should be entered in full.",
        "date_of_birth" => "Date of birth is used for identity verification and eligibility. A minor (under 18) may require a custodial arrangement. The date cannot be in the future.",
        "ssn" => "Social Security Number is required by federal regulation for tax reporting on benefit distributions. Enter in XXX-XX-XXXX format. The number is automatically masked after entry for security.",
        "address" => "This is the mailing address for benefit correspondence and distribution. PO Box addresses are acceptable. Include street, city, state, and ZIP code.",
        "relationship" => "Legal relationship to the account holder. Spouses may have statutory rights in many states. 'Contingent' beneficiaries only receive benefits if the primary beneficiary predeceases or cannot be located.",
        "percentage" => "Benefit allocation percentage. A single beneficiary should receive 100%. Multiple beneficiaries must total 100%. Common splits: 50/50 for two, 34/33/33 for three.",
        "contingent" => "A contingent beneficiary receives benefits only if the primary beneficiary predeceases the account holder or cannot be located. If unchecked, this is a primary beneficiary designation."
      }
      supplement = field_help_supplements[field_name] || ""

      field_summary = fields.map { |k, info| "  - #{info['label'] || k}: \"#{info['value']}\"" }.join("\n")
      request_id = SecureRandom.hex(8)
      messages = [
        {
          "role" => "system",
          "content" => "You are an insurance form field assistant for a \"#{form_title}\" form. The user pressed '?' on the field \"#{field_label}\". #{supplement} Explain what this field is for and what to enter. Be concise (1-3 sentences). Respond ONLY with valid JSON: {\"help\": \"your explanation\"}"
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
        warnings = parsed["warnings"] || {}

        if ok
          channel.emit("form:submit:result", { ok: true, answer: parsed["answer"], explanation: explanation, warnings: warnings })
        else
          channel.emit("sidebar:open", {})
          channel.emit("sidebar:message", { content: explanation, label: "Form Review" })
          channel.emit("form:submit:result", { ok: false, answer: parsed["answer"], explanation: explanation })
        end
      end
    end
  RUBY
end
