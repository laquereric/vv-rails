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
      end
    end
  RUBY
end
