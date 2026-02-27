# vv-rails

Rails engine gem providing server-side Vv integration via Action Cable.

## Key files

| File | Purpose |
|------|---------|
| `lib/vv/rails.rb` | Main module, requires engine/config/events/event_bus |
| `lib/vv/rails/engine.rb` | `Vv::Rails::Engine` — isolates namespace, ActionCable auto-discovery |
| `lib/vv/rails/configuration.rb` | `Vv::Rails.configure` DSL |
| `lib/vv/rails/event_bus.rb` | Server-side pub/sub: `on`, `off`, `emit` |
| `lib/vv/rails/events.rb` | 9 RES event classes + TYPE_MAP + helpers |
| `app/channels/vv_channel.rb` | Action Cable channel — receive, render_to, emit |
| `app/javascript/vv-rails/index.js` | Client JS: `connectVv()`, `disconnectVv()` |
| `lib/generators/vv/install_generator.rb` | `rails generate vv:install` |
| `vv-rails.gemspec` | Ruby >= 3.3, Rails >= 7.0 < 9, rails_event_store >= 2.0 |

**Note:** ConfigController moved to `vv-browser-manager` gem. This gem no longer mounts routes.

## Templates

| Template | Generates | Has DB |
|----------|-----------|--------|
| `templates/host.rb` | LLM relay API backend (port 3001) | Yes — full schema + ApiToken auth |
| `templates/example.rb` | Browser LLM chat demo (port 3003) | Yes — same schema, no ApiToken |
| `templates/mobile.rb` | Mobile-optimized chat PWA (port 3002) | No — thin client, talks to Host |
| `templates/platform_manager.rb` | Dev dashboard (port 3000) | Yes — HostInstance only |

All templates include both `vv-rails` and `vv-browser-manager` gems.

## Schema (host.rb + example.rb)

```
Provider  1 ──→ N  Model  1 ──→ N  Preset
                      │                │ (optional)
                      ▼                ▼
Session   1 ──→ N  Turn ────────────────→ Model + Preset
    │
    └── events via RES stream "session:{id}"
```

| Table | Purpose |
|-------|---------|
| `providers` | LLM vendor: name, api_base, encrypted api_key, requires_api_key, priority |
| `models` | Per-provider model: api_model_id, context_window, capabilities (json) |
| `presets` | Named inference params: temperature, max_tokens, system_prompt, top_p, parameters (json) |
| `sessions` | Groups events and turns |
| `event_store_events` | RES-managed. 9 event types stored in streams `"session:{id}"` |
| `turns` | One LLM request/response: model, preset, message_history snapshot (json), request, completion, token counts |
| `api_tokens` | Host only — Bearer token auth via BCrypt |

## Events (Rails Event Store)

9 typed event classes in `Vv::Rails::Events`:

| Class | message_type | Purpose |
|-------|-------------|---------|
| `FormOpened` | form_open | Form rendered |
| `FormPolled` | form_poll | 5s heartbeat |
| `FormStateChanged` | form_state | Field values changed |
| `UserInputReceived` | user_input | User chat/text input |
| `FieldHelpRequested` | field_help | User typed `?` |
| `FormErrorOccurred` | form_error | App validation error |
| `NavigationOccurred` | navigation | Page navigation |
| `DataQueried` | data_query | Data lookup |
| `AssistantResponded` | assistant | LLM response |

Helpers: `Events.for("form_open")` → class, `Events.to_message_hash(event)` → `{role, message_type, content}`.

Session methods: `session.events` reads from RES stream, `session.messages_from_events` converts to message format for Turn snapshots.

**Timeline inspection:** RES browser UI at `/res` (development) replaces rake tasks.

## Architecture pattern

Extends classic Rails form lifecycle (render → submit → validate → respond) with an ActionCable middle phase where the server observes the form being filled and accumulates context.

```
CLASSIC:  GET /new → render ─────────────────────────→ POST /create → validate → redirect
                             (server is blind)

VV:       GET /    → render → open → poll → type → poll → submit → LLM pre-validate → app submit
                              │       │      │      │      │         Turn 1              │
                              Event   Evt   Evt    Evt    Turn + Events             app errors?
                              (open) (poll) (state)(poll)  (snapshot + completion)      │
                                                                                   FormErrorOccurred
                                                                                   Turn 2 (error_resolution)
                                                                                   LLM-enhanced suggestions

FIELD HELP:  user types '?' in field → FieldHelpRequested → Turn (field_help) → help text below field
```

**Pre-submit turn:** `form:submit` creates Turn with message_history snapshot → LLM validates → `form:submit:result`. If LLM approves, form submits to application logic.

**Post-submit turn:** Application validates → returns per-field errors → `form:errors` event → FormErrorOccurred published → Turn created → LLM translates raw errors into plain-language fix suggestions → `form:error:suggestions` pushed to client with per-field hints.

**Field help:** User types `?` as first character in any field → `field:help` event → FieldHelpRequested published → Turn created → LLM explains the field → `field:help:response` pushed to client with contextual help text.

**Complexity stays in Host/EventBus.** Client fires simple events. Server handles session lookup, event publishing, model selection, prompt assembly, turn tracking, result dispatch.

## VvChannel API

```ruby
# In VvChannel (received from plugin via ActionCable):
def receive(data)
  Vv::Rails::EventBus.emit(data["event"], data["data"], { channel: self })
end

# Channel instance methods:
channel.render_to(target, html, action: "append")  # Turbo Stream to plugin
channel.emit(event, data)                            # arbitrary event to plugin
```

## EventBus API

```ruby
Vv::Rails::EventBus.on("chat") do |data, context|
  channel = context[:channel]
  channel.emit("chat:response", { content: "Hello", role: "assistant" })
end
```

## Configuration

```ruby
Vv::Rails.configure do |config|
  config.channel_prefix = "vv"           # stream prefix
  config.cable_url = "/cable"            # WebSocket URL
  config.allowed_origins = nil           # nil = allow all
  config.authenticate = ->(params) { }   # auth proc
  config.on_connect = ->(channel, params) { }
  config.on_disconnect = ->(channel, params) { }
end
```

## Gotchas

- ActionCable must be mounted: `mount ActionCable.server => "/cable"` in routes
- Host app needs `app/channels/application_cable/{connection,channel}.rb`
- For Chrome extension access: `config.action_cable.disable_request_forgery_protection = true`
- Use `async` adapter (not `solid_cable`) for simple setups
- Templates require both `vendor/vv-rails` and `vendor/vv-browser-manager` symlinks before `rails new`

## Test

```bash
gem build vv-rails.gemspec
```
