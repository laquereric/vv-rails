# vv-rails

Rails engine that provides the server-side connection point for the [Vv browser plugin](../vv-plugin) — Action Cable channels, server-side event routing, and Rails Event Store integration.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Rails App                                      │
│                                                 │
│  ┌──────────────┐  ┌────────────────────┐      │
│  │ VvChannel    │  │ ConfigController   │      │
│  │ (vv-rails)   │  │ (vv-browser-mgr)  │      │
│  │ ActionCable  │  │ GET /vv/config.json│      │
│  └──────┬───────┘  └────────────────────┘      │
│         │                                       │
│  ┌──────▼───────┐  ┌────────────────────┐      │
│  │ Vv::Rails::  │  │ Vv::Rails::        │      │
│  │ EventBus     │  │ Events (RES)       │      │
│  └──────────────┘  └────────────────────┘      │
└─────────────────────────────────────────────────┘
         ▲ WebSocket (Action Cable)
         │
┌────────┴────────┐
│  Vv Browser     │
│  Plugin         │
└─────────────────┘
```

## Installation

Add to your Gemfile (along with vv-browser-manager for the discovery endpoint):

```ruby
gem "vv-rails", path: "vendor/vv-rails"
gem "vv-browser-manager", path: "vendor/vv-browser-manager"
```

Run the install generator:

```bash
rails generate vv:install
```

This creates:
- `config/initializers/vv_rails.rb` — configuration

## Configuration

```ruby
# config/initializers/vv_rails.rb
Vv::Rails.configure do |config|
  config.channel_prefix = "vv"
  config.cable_url = "ws://localhost:3000/cable"

  # Authentication
  config.authenticate = ->(params) { User.find_by(token: params[:token]) }

  # Lifecycle callbacks
  config.on_connect = ->(channel, params) { Rails.logger.info("Vv connected") }
  config.on_disconnect = ->(channel, params) { Rails.logger.info("Vv disconnected") }
end
```

## VvChannel

The Action Cable channel that handles plugin connections. Each connection streams on a per-page channel and a global broadcast channel.

```ruby
# Receives events from the browser plugin
# Automatically routes through Vv::Rails::EventBus
VvChannel#receive(data)

# Broadcast a Turbo Stream render command to the plugin's content script
VvChannel#render_to(target, html, action: "append")

# Broadcast an arbitrary event
VvChannel#emit(event, data)
```

## Server-Side Event Bus

Register handlers for events sent from the browser plugin:

```ruby
# In an initializer or controller
Vv::Rails::EventBus.on("chat:complete") do |data, context|
  # data = payload from plugin
  # context[:channel] = the VvChannel instance
  channel = context[:channel]
  channel.render_to("responses", "<p>#{data['response']}</p>")
end
```

## Events (Rails Event Store)

9 typed event classes replace the Messages table:

```ruby
# Publish an event
event_store = Rails.configuration.event_store
event_store.publish(
  Vv::Rails::Events::FormOpened.new(data: { role: "system", content: "{}", form_title: "My Form" }),
  stream_name: "session:#{session.id}"
)

# Read events for a session
session.events                  # => [RailsEventStore::Event, ...]
session.messages_from_events    # => [{role:, message_type:, content:}, ...]

# Map message_type to event class
Vv::Rails::Events.for("form_open")  # => Vv::Rails::Events::FormOpened
```

Event timeline inspection via RES browser UI at `/res` (development).

## Plugin Discovery

The `vv-browser-manager` gem provides the config endpoint:

```
GET /vv/config.json
```

```json
{
  "cable_url": "ws://localhost:3000/cable",
  "channel": "VvChannel",
  "version": "0.9.0",
  "prefix": "vv"
}
```

## Event Flow

1. Plugin sends event via Action Cable → `VvChannel#receive`
2. Channel routes through `Vv::Rails::EventBus.emit(event, payload)`
3. Registered handlers process the event
4. Handlers publish RES events and can call `channel.render_to` or `channel.emit` to respond
5. Plugin content script applies DOM updates via Turbo Stream actions

## Templates

Application templates for generating complete Rails apps with vv-rails pre-configured.

| Template | Generates | Command |
|----------|-----------|---------|
| example  | vv-rails-example | `rails new myapp -m vendor/vv-rails/templates/example.rb` |
| host     | vv-host          | `rails new myapp -m vendor/vv-rails/templates/host.rb` |
| mobile   | vv-mobile        | `rails new myapp -m vendor/vv-rails/templates/mobile.rb` |

### example.rb

Generates a browser-side LLM chat demo with EventBus handlers for the full form lifecycle (open, poll, type, submit, errors, field help). Events stored via Rails Event Store.

### host.rb

Generates an API backend that relays LLM traffic to upstream providers and stores sessions/turns in SQLite. Includes token authentication, Action Cable relay channels, RES event storage, and a multi-provider routing system.

### mobile.rb

Generates a mobile-optimized chat UI that connects to a vv-host backend. Includes responsive touch-friendly layout, PWA manifest and service worker scaffold, and session sync via Action Cable.

## Files

| File | Purpose |
|------|---------|
| `lib/vv/rails.rb` | Main module entry |
| `lib/vv/rails/engine.rb` | Rails::Engine — ActionCable auto-discovery |
| `lib/vv/rails/configuration.rb` | `Vv::Rails.configure` block |
| `lib/vv/rails/event_bus.rb` | Server-side `on/off/emit` event routing |
| `lib/vv/rails/events.rb` | 9 RES event classes + TYPE_MAP + helpers |
| `app/channels/vv_channel.rb` | Action Cable channel |
| `app/javascript/vv-rails/index.js` | Client JS auto-connect |
| `lib/generators/vv/install_generator.rb` | `rails generate vv:install` |
| `templates/example.rb` | Application template — browser chat demo |
| `templates/host.rb` | Application template — LLM relay backend |
| `templates/mobile.rb` | Application template — mobile chat app |

## Requirements

- Ruby >= 3.3.0
- Rails >= 7.0
- Action Cable
- Rails Event Store >= 2.0
