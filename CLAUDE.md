# Vv Monorepo

Multi-repo workspace at `/Users/ericlaquer/Documents/Focus/vv/` with 13 peer modules + 1 example app.

## Modules

| Module | Role | JS entry | Gem | Tests |
|---|---|---|---|---|
| vv-event-bus | Shared pub/sub event bus | `src/index.js` / `VvEventBus` | — | `bun test` (event-bus.test.js) |
| vv-context-store | Message history (IndexedDB) | `src/VvContextStore.js` | — | `bun test` |
| vv-session-store | Session metadata (IndexedDB) | `src/VvSessionStore.js` | — | `bun test` |
| vv-model-manager | WebGPU local model inference | `src/VvModelManager.js` | — | `bun test` |
| vv-api-manager | OpenAI/Anthropic API providers | `src/VvApiManager.js` | — | `bun test` |
| vv-render | Turbo Stream DOM rendering | `src/VvRender.js` | — | `bun test` |
| vv-action-cable | Rails Action Cable WebSocket | `src/VvActionCable.js` | `vv-action-cable` | `bun test` |
| vv-mcp-manager | Model Context Protocol | `src/VvMcpManager.js` | — | `bun test` |
| vv-acp-manager | Agent Communication Protocol | `src/VvAcpManager.js` | — | `bun test` |
| vv-a2a-manager | Agent-to-Agent Protocol | `src/VvA2aManager.js` | — | `bun test` |
| vv-plugin | Chrome Extension (VvRuntime) | `src/vv-runtime.js` | — | `bun test` |
| vv-browser | Parent package, browser env | `index.js` | `vv-browser` (`Vv::Browser`) | — |
| vv-rails | Rails engine, Action Cable | — | `vv-rails` (`Vv::Rails`) | — |
| vv-rails-example | Example Rails app | — | — | `rails test` |

## Naming conventions

- **Folders**: `vv-{name}` (kebab-case, `vv-` prefix)
- **npm packages**: `vv-{name}` (matches folder)
- **JS classes**: `Vv{Name}` (PascalCase, `Vv` prefix) — e.g. `VvEventBus`, `VvModelManager`
- **JS source files**: `Vv{Name}.js` matching class name
- **Ruby gems**: `vv-{name}` (kebab-case)
- **Ruby modules**: `Vv::{Name}` — e.g. `Vv::Rails`, `Vv::Browser`, `Vv::ActionCable`
- **Ruby source files**: `lib/vv/{name}.rb` with `lib/vv/{name}/version.rb`
- **Internal classes** (providers, clients) do NOT get `Vv` prefix: `OpenAiProvider`, `MCPClient`, `ActionCableClient`
- **Backward-compat aliases** are exported for old class names where they existed

## File structure (per JS module)

```
vv-{name}/
├── VERSION              # Single version source of truth (currently 0.6.0)
├── CONTENT.md           # Module description and metadata
├── package.json         # npm metadata, version must match VERSION
├── src/Vv{Name}.js      # Main class export
├── test/Vv{Name}.test.js
├── examples/example.js
├── README.md
└── dev-server.js        # (some modules)
```

Gems additionally have:
```
├── vv-{name}.gemspec    # version reads from lib/vv/{name}/version.rb
├── lib/vv/{name}.rb     # Module + Engine
└── lib/vv/{name}/version.rb  # VERSION constant, must match VERSION file
```

## Architecture

- All JS modules import `VvEventBus` from `../../vv-event-bus/src/index.js` (relative sibling paths)
- Constructor pattern: `new Vv{Name}(config, eventBus)`
- `VvRuntime` (vv-plugin) is the composition kernel that wires all modules together
- Protocol managers (MCP/ACP/A2A) are initialized on demand via `configure{Protocol}()`
- `VvActionCable` bridges to Rails via WebSocket

## Version management

- `VERSION` file in each repo root is the single source of truth
- `package.json` `"version"` must match VERSION
- Ruby `Vv::{Name}::VERSION` constant must match VERSION
- Gemspec reads version via `require_relative "lib/vv/{name}/version"`
- All modules are currently at version **0.6.0**

## Build & test

- **Runtime**: Bun (test runner + bundler)
- **Test**: `bun test` in each module directory
- **Build gems**: `gem build vv-{name}.gemspec`
- **Build plugin**: `bun run build` in vv-plugin (outputs to `dist/`)
- **vv-rails-example**: standard Rails app (`bundle install`, `rails server`)

## GitHub repos

All repos under `https://github.com/laquereric/vv-{name}`

## Cross-module changes

When modifying a class name, import path, or API surface in any module:
1. Update the source module's `src/`, `test/`, `examples/`, docs
2. Update `vv-plugin/src/vv-runtime.js` (imports + instantiation)
3. Update `vv-plugin/src/content.js` if render/rails references changed
4. Grep across all peer modules: `grep -r "OldName" /Users/ericlaquer/Documents/Focus/vv/vv-*/src/`
5. Run `bun test` in each affected module
6. Rebuild `vv-plugin` if imports changed
