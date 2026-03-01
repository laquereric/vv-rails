# vv-rails / library

Bindable layer — stateless Ruby with no Rails dependencies.

## Contents

- `Configuration` — pure DSL for channel_prefix, cable_url, auth callbacks
- `EventBus` — pure Ruby pub/sub (listeners hash, emit/on/off)
- `Events` — RES event classes (9 form lifecycle + assistant events)
- `Manifest` — JSON manifest reader/writer for gg template registration
