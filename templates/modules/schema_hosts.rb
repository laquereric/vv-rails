# modules/schema_hosts.rb — HostInstance table (platform_manager)
#
# Depends on: base

after_bundle do
  generate "migration", "CreateHostInstances name:string url:string cable_url:string active:boolean last_seen_at:datetime"

  file "app/models/host_instance.rb", <<~RUBY
    class HostInstance < ApplicationRecord
      validates :name, presence: true, uniqueness: true
      validates :url, presence: true
      validates :cable_url, presence: true

      scope :active, -> { where(active: true) }

      def status
        return "unknown" if last_seen_at.nil?
        last_seen_at > 30.seconds.ago ? "connected" : "disconnected"
      end
    end
  RUBY
end
