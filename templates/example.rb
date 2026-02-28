# vv-rails example template
#
# Browser-side LLM demo: beneficiary form with real-time EventBus handlers,
# plugin detection, WebLLM inference, field help, and form lifecycle events.
#
# Delegates to composer.rb with the 'example' profile.
# See profiles.yml for module list and config.
# Original monolithic template preserved as example_monolithic.rb.

ENV["VV_PROFILE"] ||= "example"
apply File.join(File.dirname(__FILE__), "composer.rb")
