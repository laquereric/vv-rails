# vv-rails

Rails engine that provides the server-side connection point for the [Vv browser plugin](../vv-plugin) — Action Cable channels, server-side event routing, and generators.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Rails App + vv-rails                           │
│                                                 │
│  ┌──────────────┐  ┌────────────────────┐      │
│  │ VvChannel    │  │ Vv::ConfigController│      │
│  │ (ActionCable)│  │ GET /vv/config.json │      │
│  └──────┬───────┘  └────────────────────┘      │
│         │                                       │
│  ┌──────▼───────┐  ┌────────────────────┐      │
│  │ Vv::Rails::  │  │ Vv::Rails::        │      │
│  │ EventBus     │  │ Configuration      │      │
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

Add to your Gemfile:

```ruby
gem "vv-rails", path: "vendor/vv-rails"
```

Run the install generator:

```bash
rails generate vv:install
```

This creates:
- `config/initializers/vv_rails.rb` — configuration
- Adds `mount Vv::Rails::Engine => '/vv'` to your routes

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

## Client JS

Auto-connect the plugin from your Rails app's JavaScript:

```js
import { connectVv } from 'vv-rails';

// Manual connect
connectVv({ cableUrl: '/cable', channel: 'VvChannel' });
```

Or use the `data-vv-auto` attribute for automatic connection:

```html
<body data-vv-auto data-page-id="home">
```

## Plugin Discovery

The config endpoint lets the plugin discover connection details:

```
GET /vv/config.json
```

```json
{
  "cable_url": "ws://localhost:3000/cable",
  "channel": "VvChannel",
  "version": "0.1.0",
  "prefix": "vv"
}
```

## Event Flow

1. Plugin sends event via Action Cable → `VvChannel#receive`
2. Channel routes through `Vv::Rails::EventBus.emit(event, payload)`
3. Registered handlers process the event
4. Handlers can call `channel.render_to` or `channel.emit` to respond
5. Plugin content script applies DOM updates via Turbo Stream actions

## Files

| File | Purpose |
|------|---------|
| `lib/vv/rails.rb` | Main module entry |
| `lib/vv/rails/engine.rb` | Rails::Engine — mounts at `/vv` |
| `lib/vv/rails/configuration.rb` | `Vv::Rails.configure` block |
| `lib/vv/rails/event_bus.rb` | Server-side `on/off/emit` event routing |
| `app/channels/vv_channel.rb` | Action Cable channel |
| `app/controllers/vv/config_controller.rb` | Plugin discovery endpoint |
| `app/javascript/vv-rails/index.js` | Client JS auto-connect |
| `lib/generators/vv/install_generator.rb` | `rails generate vv:install` |

## Requirements

- Ruby >= 3.3.0
- Rails >= 7.0
- Action Cable
