# modules/schema_settings.rb — Key-value settings table (mobile)
#
# Depends on: base

after_bundle do
  generate "migration", "CreateSettings key:string:uniq value:text"

  file "app/models/setting.rb", <<~RUBY
    class Setting < ApplicationRecord
      validates :key, presence: true, uniqueness: true

      def self.get(key, default = nil)
        find_by(key: key)&.value || default
      end

      def self.set(key, value)
        setting = find_or_initialize_by(key: key)
        setting.update!(value: value)
        value
      end

      def self.host_url
        get("host_url", ENV.fetch("VV_HOST_URL", "http://localhost:3001"))
      end

      def self.api_token
        get("api_token")
      end

      def self.default_model
        get("default_model")
      end
    end
  RUBY
end
