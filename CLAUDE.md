# vv-rails

Rails engine gem providing server-side Vv integration via Action Cable.

## Key files

| File | Purpose |
|------|---------|
| `lib/vv/rails.rb` | Main module, requires engine/config/event_bus |
| `lib/vv/rails/engine.rb` | `Vv::Rails::Engine` — isolates namespace, auto-mounts at `/vv` |
| `lib/vv/rails/configuration.rb` | `Vv::Rails.configure` DSL |
| `lib/vv/rails/event_bus.rb` | Server-side pub/sub: `on`, `off`, `emit` |
| `app/channels/vv_channel.rb` | Action Cable channel — receive, render_to, emit |
| `app/controllers/vv/config_controller.rb` | `GET /vv/config.json` — plugin discovery |
| `app/javascript/vv-rails/index.js` | Client JS: `connectVv()`, `disconnectVv()` |
| `lib/generators/vv/install_generator.rb` | `rails generate vv:install` |
| `vv-rails.gemspec` | Ruby >= 3.3, Rails >= 7.0 < 9 |

## Templates

| Template | Generates | Has DB |
|----------|-----------|--------|
| `templates/host.rb` | LLM relay API backend (port 3001) | Yes — full schema + ApiToken auth |
| `templates/example.rb` | Browser LLM chat demo (port 3003) | Yes — same schema, no ApiToken |
| `templates/mobile.rb` | Mobile-optimized chat PWA (port 3002) | No — thin client, talks to Host |
| `templates/platform_manager.rb` | Dev dashboard (port 3000) | Yes — HostInstance only |

## Schema (host.rb + example.rb)

```
Provider  1 ──→ N  Model  1 ──→ N  Preset
                      │                │ (optional)
                      ▼                ▼
Session   1 ──→ N  Turn ────────────────→ Model + Preset
          1 ──→ N  Message
```

| Table | Purpose |
|-------|---------|
| `providers` | LLM vendor: name, api_base, encrypted api_key, requires_api_key, priority |
| `models` | Per-provider model: api_model_id, context_window, capabilities (json) |
| `presets` | Named inference params: temperature, max_tokens, system_prompt, top_p, parameters (json) |
| `sessions` | Groups messages and turns |
| `messages` | Context entries: role (user/assistant/system), message_type (user_input/navigation/data_query/form_state/form_open/form_poll) |
| `turns` | One LLM request/response: model, preset, message_history snapshot (json), request, completion, token counts |
| `api_tokens` | Host only — Bearer token auth via BCrypt |

## Architecture pattern

Extends classic Rails form lifecycle (render → submit → validate → respond) with an ActionCable middle phase where the server observes the form being filled and accumulates context.

```
CLASSIC:  GET /new → render ─────────────────────────→ POST /create → validate → redirect
                             (server is blind)

VV:       GET /    → render → open → poll → type → poll → submit → LLM validate → result
                              │       │      │      │      │
                              Message  Msg   Msg    Msg    Turn + Messages
                              (open)  (poll) (state)(poll)  (snapshot + completion)
```

**Form lifecycle:** `GET /` renders form → `form:open` records form appearance → `form:poll` heartbeats every 5s (with focused_field) → `chat:typing` persists form_state on changes → `form:submit` creates Turn with message_history snapshot → `llm:request`/`llm:response` completes Turn → `form:submit:result` pushed to client.

**Single-table timeline:** `session.messages.order(:created_at)` gives you the full temporal view. No joins. Detect patterns like "paused 12s between field 3 and 4" by comparing form_poll timestamps and focused_field values.

**Complexity stays in Host/EventBus.** Client fires simple events. Server handles session lookup, message persistence, model selection, prompt assembly, turn tracking, result dispatch.

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

## Test

```bash
gem build vv-rails.gemspec
```
