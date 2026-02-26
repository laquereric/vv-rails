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

| Template | Generates |
|----------|-----------|
| `templates/example.rb` | Browser LLM chat demo (port 3003) |
| `templates/host.rb` | LLM relay API backend (port 3001) |
| `templates/mobile.rb` | Mobile-optimized chat PWA (port 3002) |
| `templates/platform_manager.rb` | Dev dashboard (port 3000) |

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
