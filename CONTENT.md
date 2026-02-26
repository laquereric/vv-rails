# vv-rails

Rails engine gem that provides server-side integration for the Vv browser plugin, enabling bidirectional communication between Rails applications and the plugin via Action Cable WebSockets. Exposes an ActionCable channel (`VvChannel`), a configuration module for authentication and lifecycle callbacks, a server-side event bus for routing and handling events, and generators for easy installation. Includes client-side JavaScript for auto-connecting the plugin to the Rails server.

- **Gem name**: vv-rails
- **Ruby**: >= 3.3.0
- **Rails**: >= 7.0, < 9
- **Dependencies**: railties, actioncable
- **License**: MIT
