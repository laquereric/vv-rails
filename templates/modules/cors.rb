# modules/cors.rb — CORS middleware
#
# Config vars (set before apply):
#   @cors_resources — array of resource path patterns (default: standard API paths)

gem "rack-cors"

after_bundle do
  default_resources = [
    { path: "/v1/*",  methods: "[:get, :post, :put, :patch, :delete, :options]" },
    { path: "/api/*", methods: "[:get, :post, :put, :patch, :delete, :options]" },
    { path: "/vv/*",  methods: "[:get, :options]" }
  ]

  resources = if @cors_resources.is_a?(Array) && @cors_resources.first.is_a?(Hash)
    @cors_resources
  elsif @cors_resources.is_a?(Array)
    # Profile passes simple string paths — expand with default methods
    @cors_resources.map { |p| { path: p, methods: "[:get, :post, :put, :patch, :delete, :options]" } }
  else
    default_resources
  end

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
