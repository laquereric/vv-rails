# modules/cors.rb — CORS middleware
#
# Config vars (set before apply):
#   @cors_resources — array of resource path patterns (default: standard API paths)

gem "rack-cors"

after_bundle do
  resources = @cors_resources || [
    { path: "/v1/*",  methods: "[:get, :post, :put, :patch, :delete, :options]" },
    { path: "/api/*", methods: "[:get, :post, :put, :patch, :delete, :options]" },
    { path: "/vv/*",  methods: "[:get, :options]" }
  ]

  resource_lines = resources.map { |r|
    "      resource \"#{r[:path]}\", headers: :any, methods: #{r[:methods]}"
  }.join("\n")

  initializer "cors.rb", <<~RUBY
    Rails.application.config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins "*"
#{resource_lines}
      end
    end
  RUBY
end
