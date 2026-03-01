# modules/api_containers.rb — Docker container control API
#
# Depends on: base

after_bundle do
  file "app/services/docker_service.rb", <<~'RUBY'
    class DockerService
      COMPOSE_PROJECT = ENV.fetch("COMPOSE_PROJECT_NAME", "vv-platform")

      def self.containers
        json = `docker compose -p #{COMPOSE_PROJECT} ps --format json 2>/dev/null`
        return [] if json.blank?

        json.lines.filter_map do |line|
          data = JSON.parse(line) rescue next
          service = data["Service"]
          health = data["Health"].presence

          unless health
            cached = Rails.cache.read("health_check:#{service}")
            if cached
              ago = (Time.current - cached[:checked_at]).round
              health = "#{cached[:status]} (#{ago}s ago)"
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
    end
  RUBY

  file "app/jobs/health_check_job.rb", <<~'RUBY'
    require "net/http"

    class HealthCheckJob < ApplicationJob
      queue_as :default

      def perform
        DockerService.containers.each do |c|
          service = c[:service]
          next if service == "platform_manager"
          next unless c[:state] == "running"

          status = ping("http://#{service}:80/up") ? "healthy" : "unhealthy"
          Rails.cache.write("health_check:#{service}", { status: status, checked_at: Time.current })
        end

        self.class.set(wait: 60.seconds).perform_later
      end

      private

      def ping(url)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = 5
        http.read_timeout = 5
        response = http.get(uri.path)
        response.code.to_i < 400
      rescue StandardError
        false
      end
    end
  RUBY

  initializer "health_check.rb", <<~'RUBY'
    Rails.application.config.after_initialize do
      HealthCheckJob.perform_later if defined?(Rails::Server)
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
      end
    end
  RUBY
end
