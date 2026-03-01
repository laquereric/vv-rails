# modules/api_containers.rb — Docker container control API + repo metadata
#
# Depends on: base


@vv_applied_modules ||= []; @vv_applied_modules << "api_containers"

after_bundle do
  file "app/services/docker_service.rb", <<~'RUBY'
    require "yaml"

    class DockerService
      COMPOSE_PROJECT = ENV.fetch("COMPOSE_PROJECT_NAME", "vv-platform")

      def self.containers
        json = `docker compose -p #{COMPOSE_PROJECT} ps --format json 2>/dev/null`
        return [] if json.blank?

        metadata = repo_metadata

        json.lines.filter_map do |line|
          data = JSON.parse(line) rescue next
          service = data["Service"]
          health = data["Health"].presence

          # Merge health from metadata cache if not available from Docker
          unless health
            meta = metadata.find { |m| m.dig("local_container", "service") == service }
            if meta && meta.dig("local_container", "health")
              health = meta.dig("local_container", "health")
            else
              health = "N/A"
            end
          end

          {
            id: data["ID"],
            name: data["Name"],
            service: service,
            state: data["State"],
            status: data["Status"],
            ports: data["Ports"].to_s.scan(/(?<=:)\d+(?=->)/).uniq.join(", "),
            health: health
          }
        end
      end

      def self.restart(container_id)
        system("docker", "restart", container_id.to_s)
      end

      def self.stop(container_id)
        system("docker", "stop", container_id.to_s)
      end

      def self.start(container_id)
        system("docker", "start", container_id.to_s)
      end

      # --- Repo metadata ---

      def self.repo_metadata
        Rails.cache.fetch("repo_metadata", expires_in: 5.minutes) { [] }
      end

      def self.all_metadata
        repo_metadata
      end

      def self.vv_repos
        repo_metadata.select { |m| m["name"]&.start_with?("vv-") }
      end

      def self.gg_repos
        repo_metadata.select { |m| m["name"]&.start_with?("gg-") }
      end
    end
  RUBY

  file "app/jobs/metadata_collector_job.rb", <<~'RUBY'
    require "yaml"

    class MetadataCollectorJob < ApplicationJob
      queue_as :default

      VV_BIN   = "/rails/vv-bin/vv-metadata"
      VV_ROOT  = "/rails/vv"
      GG_ROOT  = "/rails/gg"

      def perform
        # Run vv-metadata script if available
        if File.exist?(VV_BIN)
          system("ruby", VV_BIN, "--vv-root", VV_ROOT, "--gg-root", GG_ROOT,
                 out: File::NULL, err: File::NULL)
        end

        # Glob and parse all METADATA.yml files
        files = Dir.glob("#{VV_ROOT}/vv-*/METADATA.yml") +
                Dir.glob("#{GG_ROOT}/gg-*/METADATA.yml")

        metadata = files.filter_map do |path|
          YAML.safe_load_file(path) rescue nil
        end

        Rails.cache.write("repo_metadata", metadata, expires_in: 5.minutes)

        # Re-enqueue
        self.class.set(wait: 60.seconds).perform_later
      rescue StandardError => e
        Rails.logger.error("[MetadataCollectorJob] #{e.message}")
        self.class.set(wait: 60.seconds).perform_later
      end
    end
  RUBY

  initializer "metadata_collector.rb", <<~'RUBY'
    Rails.application.config.after_initialize do
      MetadataCollectorJob.perform_later if defined?(Rails::Server)
    end
  RUBY

  file "app/controllers/api/local/containers_controller.rb", <<~RUBY
    module Api
      module Local
        class ContainersController < ActionController::API
          def index
            render json: DockerService.containers
          end

          def restart
            DockerService.restart(params[:id])
            render json: { status: "restarting", id: params[:id] }
          end

          def stop
            DockerService.stop(params[:id])
            render json: { status: "stopping", id: params[:id] }
          end

          def start
            DockerService.start(params[:id])
            render json: { status: "starting", id: params[:id] }
          end
        end
      end
    end
  RUBY

  file "app/controllers/api/local/repos_controller.rb", <<~RUBY
    module Api
      module Local
        class ReposController < ActionController::API
          def index
            metadata = DockerService.all_metadata

            case params[:filter]
            when "vv"
              metadata = DockerService.vv_repos
            when "gg"
              metadata = DockerService.gg_repos
            end

            render json: metadata
          end
        end
      end
    end
  RUBY

  # --- ManifestService ---

  file "app/services/manifest_service.rb", <<~'RUBY'
    require "net/http"
    require "json"
    require "yaml"

    class ManifestService
      CACHE_TTL = 60.seconds

      def self.fetch_all
        Rails.cache.fetch("container_manifests", expires_in: CACHE_TTL) do
          containers = DockerService.containers
          containers.filter_map do |c|
            port = c[:ports].to_s.split(",").first&.strip
            next unless port.present? && port.match?(/\A\d+\z/)

            manifest = fetch_manifest(port.to_i)
            next unless manifest

            {
              service: c[:service] || c[:name],
              port: port.to_i,
              state: c[:state],
              manifest: manifest
            }
          end
        end
      end

      def self.fetch_manifest(port)
        uri = URI("http://localhost:#{port}/vv/manifest.json")
        response = Net::HTTP.start(uri.host, uri.port, open_timeout: 3, read_timeout: 3) do |http|
          http.get(uri.request_uri)
        end
        return nil unless response.is_a?(Net::HTTPSuccess)
        JSON.parse(response.body)
      rescue Errno::ECONNREFUSED, Timeout::Error, JSON::ParserError, Net::OpenTimeout, SocketError
        nil
      end

      def self.version_summary
        manifests = fetch_all
        summary = { vv_version: {}, ruby_version: {}, rails_version: {} }
        mismatches = []

        manifests.each do |m|
          manifest = m[:manifest]
          %w[vv_version ruby_version rails_version].each do |field|
            val = manifest[field]
            summary[field.to_sym][val] ||= []
            summary[field.to_sym][val] << m[:service]
          end
        end

        summary.each do |field, versions|
          next if versions.size <= 1
          expected = versions.max_by { |_, services| services.length }.first
          versions.each do |version, services|
            next if version == expected
            mismatches << {
              field: field.to_s,
              expected: expected,
              actual: Hash[services.map { |s| [s, version] }]
            }
          end
        end

        { manifests: manifests, version_summary: summary, mismatches: mismatches }
      end

      def self.detect_drift
        profiles = load_profiles
        current_version = fetch_all.map { |m| m[:manifest]["vv_version"] }.compact.tally.max_by(&:last)&.first

        fetch_all.map do |container|
          manifest = container[:manifest]
          profile_name = manifest["profile"]
          issues = []

          if profile_name == "custom"
            issues << { category: "custom_modules", severity: "info", detail: "Built with VV_MODULES (no profile comparison)" }
          elsif profiles[profile_name].nil?
            issues << { category: "profile_unknown", severity: "high", detail: "Profile '#{profile_name}' not found in profiles.yml" }
          else
            expected = profiles[profile_name]["modules"] || []
            actual = manifest["modules"] || []

            (expected - actual).each do |mod|
              issues << { category: "missing_module", severity: "high", detail: "Module '#{mod}' expected by profile but not in manifest" }
            end
            (actual - expected).each do |mod|
              issues << { category: "extra_module", severity: "medium", detail: "Module '#{mod}' in manifest but not expected by profile" }
            end
          end

          if current_version && manifest["vv_version"] != current_version
            issues << { category: "version_mismatch", severity: "high", detail: "vv_version #{manifest['vv_version']} != #{current_version}" }
          end

          { service: container[:service], profile: profile_name, status: issues.any? { |i| i[:severity] != "info" } ? "drifted" : "ok", issues: issues }
        end
      end

      def self.load_profiles
        paths = [
          "/rails/vv/vv-rails/templates/profiles.yml",
          File.join(ENV.fetch("VV_PATH", ""), "vv-rails/templates/profiles.yml"),
          File.expand_path("~/Documents/Focus/vv/vv-rails/templates/profiles.yml")
        ]
        path = paths.find { |p| File.exist?(p) }
        path ? YAML.safe_load_file(path) : {}
      rescue StandardError
        {}
      end

      private_class_method :fetch_manifest, :load_profiles
    end
  RUBY

  file "app/controllers/api/local/manifests_controller.rb", <<~RUBY
    module Api
      module Local
        class ManifestsController < ActionController::API
          def index
            render json: ManifestService.version_summary
          end

          def drift
            render json: { drift: ManifestService.detect_drift }
          end
        end
      end
    end
  RUBY

  route <<~RUBY
    namespace :api do
      namespace :local do
        resources :containers, only: [:index] do
          member do
            post :start
            post :stop
            post :restart
          end
        end
        resources :repos, only: [:index]
        resources :manifests, only: [:index] do
          collection do
            get :drift
          end
        end
      end
    end
  RUBY
end
