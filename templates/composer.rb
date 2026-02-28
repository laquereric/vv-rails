# templates/composer.rb — Composable template entry point
#
# Reads a profile name or module list and applies modules in order.
#
# Usage:
#   VV_PROFILE=host rails new myapp -m templates/composer.rb
#   VV_MODULES=base,cors,api_rest rails new myapp -m templates/composer.rb
#   TEMPLATE=host rails new myapp -m templates/composer.rb  (legacy compat)
#
# Profiles are defined in templates/profiles.yml.
# Custom module lists bypass profiles and apply modules in the given order.

require "yaml"

profiles_path = File.join(File.dirname(__FILE__), "profiles.yml")
profiles = YAML.load_file(profiles_path)

# --- Resolve profile name ---

profile_name = ENV["VV_PROFILE"] || ENV["TEMPLATE"]
module_list  = ENV["VV_MODULES"]

if module_list
  # Custom module list — no profile config, just apply in order
  modules = module_list.split(",").map(&:strip)
  config  = {}
  say "Vv Composer: custom modules [#{modules.join(", ")}]"
elsif profile_name && profiles[profile_name]
  profile = profiles[profile_name]
  modules = profile["modules"]
  config  = profile["config"] || {}
  say "Vv Composer: profile '#{profile_name}' → [#{modules.join(", ")}]"
elsif profile_name
  say "Vv Composer: unknown profile '#{profile_name}', falling back to 'example'"
  profile = profiles["example"]
  modules = profile["modules"]
  config  = profile["config"] || {}
else
  say "Vv Composer: no profile specified, using 'example'"
  profile = profiles["example"]
  modules = profile["modules"]
  config  = profile["config"] || {}
end

# --- Set config vars as instance variables ---

@vv_channel_prefix = config["vv_channel_prefix"] if config["vv_channel_prefix"]
@vv_cable_url      = config["vv_cable_url"]      if config["vv_cable_url"]
@vv_app_title      = config["vv_app_title"]       if config["vv_app_title"]
@vv_app_subtitle   = config["vv_app_subtitle"]    if config["vv_app_subtitle"]
@cors_resources    = config["cors_resources"]      if config["cors_resources"]

# --- Apply modules ---

modules_dir = File.join(File.dirname(__FILE__), "modules")

modules.each do |mod|
  mod_path = File.join(modules_dir, "#{mod}.rb")
  if File.exist?(mod_path)
    say "  → applying #{mod}"
    apply mod_path
  else
    say "  ✗ module not found: #{mod}", :red
  end
end

say "Vv Composer: done (#{modules.length} modules applied)"
