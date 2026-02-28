# vv-rails mobile template
#
# Mobile-optimized chat UI: connects to host via Llama Stack API,
# SSE streaming, PWA manifest, offline support, settings management.
#
# Delegates to composer.rb with the 'mobile' profile.
# See profiles.yml for module list and config.
# Original monolithic template preserved as mobile_monolithic.rb.

ENV["VV_PROFILE"] ||= "mobile"
apply File.join(File.dirname(__FILE__), "composer.rb")
