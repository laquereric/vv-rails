# modules/ui_design_system.rb — Design System foundation for all UI modules
#
# Provides: DS CSS variables injection, shared layout with theme switcher,
# CDN font loading, ViewComponent helpers availability.
#
# Depends on: base (which provides engine-design-system gem)
# Must be applied BEFORE any ui_* module.


@vv_applied_modules ||= []; @vv_applied_modules << "ui_design_system"

after_bundle do
  # --- D6: Ensure design system classes are loaded ---

  initializer "design_system_loader.rb", <<~RUBY
    # Explicitly load design system token and CSS classes
    # (Zeitwerk may not auto-load these from the engine gem)
    begin
      gem_spec = Gem.loaded_specs["engine-design-system"]
      if gem_spec
        require gem_spec.full_gem_path + "/lib/engine_design_system/token_loader"
        require gem_spec.full_gem_path + "/lib/engine_design_system/css_variable_generator"
      end
    rescue StandardError => e
      Rails.logger.warn "[design_system] Could not load token classes: \#{e.message}"
    end
  RUBY

  # --- D6: Design token CSS injection ---

  file "app/helpers/design_system_helper.rb", <<~'RUBY'
    module DesignSystemHelper
      # Inject design token CSS variables into the <head>
      def vv_design_tokens_style_tag
        return "" unless defined?(EngineDesignSystem::CssVariableGenerator)

        css = EngineDesignSystem::CssVariableGenerator.generate
        tag.style(css.html_safe, nonce: content_security_policy_nonce)
      rescue StandardError => e
        Rails.logger.warn "[design_system] CSS generation error: #{e.message}"
        ""
      end

      # Theme toggle data attribute for <html> tag
      def vv_theme_attribute
        "light" # Default; JS can toggle to "dark"
      end
    end
  RUBY

  # --- D6: Shared layout partial ---

  file "app/views/shared/_vv_head.html.erb", <<~'ERB'
    <!-- Vv Design System: Tokens + Fonts -->
    <%= vv_design_tokens_style_tag %>
    <link rel="preconnect" href="https://fonts.bunny.net">
    <link href="https://fonts.bunny.net/css?family=inter:400,500,600,700|jetbrains-mono:400,500" rel="stylesheet">
    <style>
      /* DS Foundation Reset */
      *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
      body {
        font-family: var(--vv-font-sans, Inter, system-ui, sans-serif);
        background: var(--vv-background, #f0f2f5);
        color: var(--vv-text, #333);
        min-height: 100vh;
      }
      code, pre { font-family: var(--vv-font-mono, 'JetBrains Mono', ui-monospace, monospace); }
    </style>
  ERB

  # --- D6: Theme switcher Stimulus controller ---

  file "app/javascript/controllers/vv_theme_controller.js", <<~'JS'
    import { Controller } from "@hotwired/stimulus"

    export default class extends Controller {
      connect() {
        const saved = localStorage.getItem("vv-theme")
        if (saved) {
          document.documentElement.setAttribute("data-theme", saved)
        } else if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
          document.documentElement.setAttribute("data-theme", "dark")
        }
      }

      toggle() {
        const current = document.documentElement.getAttribute("data-theme") || "light"
        const next = current === "dark" ? "light" : "dark"
        document.documentElement.setAttribute("data-theme", next)
        localStorage.setItem("vv-theme", next)
      }
    }
  JS

  # --- D3/D4/D5: DS-aware CSS variables consumed by ui_dashboard, ui_chat, ui_example_form ---

  file "app/assets/stylesheets/vv_design_system.css", <<~'CSS'
    /* Vv Design System Foundation
       This file provides CSS custom property mappings that all ui_* modules reference.
       Colors, typography, spacing, and shadows are driven by design tokens. */

    /* Semantic color aliases — map DS tokens to component-level vars */
    :root {
      /* Header */
      --pm-header-bg: var(--vv-header-bg, #1a1a2e);
      --pm-header-text: var(--vv-header-text, rgba(255,255,255,0.85));
      --pm-header-text-secondary: var(--vv-header-text-secondary, rgba(255,255,255,0.7));

      /* Cards & surfaces */
      --pm-surface: var(--vv-surface, #ffffff);
      --pm-surface-shadow: var(--vv-shadow-md, 0 2px 12px rgba(0,0,0,0.08));
      --pm-border: var(--vv-border, #e4e4e7);
      --pm-radius: var(--vv-radius-lg, 12px);

      /* Text */
      --pm-text: var(--vv-text, #333);
      --pm-text-secondary: var(--vv-text-secondary, #555);
      --pm-text-muted: var(--vv-text-muted, #888);

      /* Accent */
      --pm-accent: var(--vv-accent, #667eea);
      --pm-accent-hover: var(--vv-accent-hover, #5a6fd6);
      --pm-accent-gradient: linear-gradient(135deg, var(--vv-color-primary-500, #667eea), var(--vv-color-primary-700, #764ba2));

      /* Status */
      --pm-success: var(--vv-color-success-600, #16a34a);
      --pm-danger: var(--vv-color-danger-600, #dc2626);
      --pm-warning: var(--vv-color-warning-600, #d97706);
      --pm-info: var(--vv-color-primary-600, #2563eb);

      /* Spacing */
      --pm-gap: var(--vv-space-4, 16px);
      --pm-gap-sm: var(--vv-space-2, 8px);
      --pm-gap-lg: var(--vv-space-6, 24px);
    }

    /* Dark theme overrides */
    [data-theme="dark"] {
      --pm-header-bg: var(--vv-header-bg, #0a0a1a);
      --pm-surface: var(--vv-surface, #27272a);
      --pm-surface-shadow: 0 2px 12px rgba(0,0,0,0.3);
      --pm-border: var(--vv-border, #3f3f46);
      --pm-text: var(--vv-text, #fafafa);
      --pm-text-secondary: var(--vv-text-secondary, #d4d4d8);
      --pm-text-muted: var(--vv-text-muted, #71717a);
      --pm-accent: var(--vv-accent, #60a5fa);
    }
  CSS
end
