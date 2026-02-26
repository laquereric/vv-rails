require_relative "lib/vv/rails/version"

Gem::Specification.new do |spec|
  spec.name        = "vv-rails"
  spec.version     = Vv::Rails::VERSION
  spec.authors     = ["Vv"]
  spec.summary     = "Server-side Vv integration for Rails via Action Cable"
  spec.description = "Provides Action Cable channels, event routing, and generators for Rails apps to communicate bidirectionally with the Vv browser plugin."
  spec.homepage    = "https://github.com/laquereric/vv-rails"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.files = Dir[
    "lib/**/*",
    "app/**/*",
    "config/**/*",
    "templates/**/*",
    "VERSION",
    "vv-rails.gemspec",
  ]

  spec.add_dependency "railties",    ">= 7.0", "< 9"
  spec.add_dependency "actioncable", ">= 7.0", "< 9"
end
