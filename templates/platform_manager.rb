# vv-rails platform_manager template
#
# Development dashboard: Docker container monitoring/control,
# remote host instance tracking, real-time container status via ActionCable.
#
# Delegates to composer.rb with the 'platform_manager' profile.
# See profiles.yml for module list and config.
# Original monolithic template preserved as platform_manager_monolithic.rb.

ENV["VV_PROFILE"] ||= "platform_manager"
apply File.join(File.dirname(__FILE__), "composer.rb")
