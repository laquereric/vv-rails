# vv-rails local_provider template
#
# Local Ollama inference bridge: handles llm:request events via EventBus,
# forwards to Ollama HTTP API, health endpoint, CORS for browser access.
#
# Delegates to composer.rb with the 'local_provider' profile.
# See profiles.yml for module list and config.
# Original monolithic template preserved as local_provider_monolithic.rb.

ENV["VV_PROFILE"] ||= "local_provider"
apply File.join(File.dirname(__FILE__), "composer.rb")
