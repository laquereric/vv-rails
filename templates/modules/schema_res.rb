# modules/schema_res.rb — Rails Event Store migration + initializer config
#
# Depends on: base


@vv_applied_modules ||= []; @vv_applied_modules << "schema_res"

gem "rails_event_store"

after_bundle do
  generate "rails_event_store_active_record:migration"

  # Append RES client to initializer
  append_to_file "config/initializers/vv_rails.rb", <<~RUBY

    Rails.configuration.to_prepare do
      Rails.configuration.event_store = RailsEventStore::Client.new
    end
  RUBY

  route 'mount RailsEventStore::Browser => "/res" if Rails.env.development?'
end
