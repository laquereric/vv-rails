# vv-rails host template
#
# API backend: LLM relay, sessions/turns/presets, Rails Event Store,
# multi-device ActionCable hub. Token-authenticated REST API.
#
# Delegates to composer.rb with the 'host' profile.
# See profiles.yml for module list and config.
# Original monolithic template preserved as host_monolithic.rb.

ENV["VV_PROFILE"] ||= "host"
apply File.join(File.dirname(__FILE__), "composer.rb")
