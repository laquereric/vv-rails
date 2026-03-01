require "json"
require "fileutils"

module Vv
  module Manifest
    def self.register_gg_template(name:, version: nil, path: nil)
      root = path || Dir.pwd
      manifest_path = File.join(root, "config", "vv_manifest.json")
      return unless File.exist?(manifest_path)

      manifest = JSON.parse(File.read(manifest_path))
      manifest["gg_templates"] ||= []
      manifest["gg_templates"] << {
        "name" => name.to_s,
        "version" => version || "unknown",
        "applied_at" => Time.now.utc.iso8601
      }

      File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")

      # Update public copy
      public_path = File.join(root, "public", "vv", "manifest.json")
      if File.exist?(File.dirname(public_path))
        FileUtils.cp(manifest_path, public_path)
      end
    end
  end
end
